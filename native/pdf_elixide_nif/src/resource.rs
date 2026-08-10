use std::{
    ops::{Deref, DerefMut},
    panic::{catch_unwind, AssertUnwindSafe},
    sync::{RwLock, RwLockReadGuard, RwLockWriteGuard},
};

use rustler::NifResult;

use crate::error::{closed_err, lock_err, panic_err};

// A BEAM resource with shared reads, exclusive mutation and explicit release.
// Access goes through closures so no lock guard can escape panic containment.
pub struct Closable<T> {
    label: &'static str,
    value: RwLock<Option<T>>,
}

impl<T> Closable<T> {
    pub fn new(label: &'static str, value: T) -> Self {
        Self {
            label,
            value: RwLock::new(Some(value)),
        }
    }

    // Use only for `&mut` work or effects that must be atomic against readers.
    pub fn with_lock<R>(&self, f: impl FnOnce(&mut T) -> NifResult<R>) -> NifResult<R> {
        // The guard is bound here, in the caller's frame, rather than inside the
        // closure — that is what keeps a panic from poisoning the lock (see
        // `contain_panic`).
        let mut guard = self.lock()?;

        contain_panic(|| f(&mut guard))
    }

    // Shared access is the default and still excludes `close`.
    pub fn with_read<R>(&self, f: impl FnOnce(&T) -> NifResult<R>) -> NifResult<R> {
        let guard = self.read()?;

        contain_panic(|| f(&guard))
    }

    fn lock(&self) -> NifResult<ExclusiveGuard<'_, T>> {
        let guard = self.value.write().map_err(|_| lock_err())?;
        if guard.is_none() {
            return Err(closed_err(self.label));
        }

        Ok(ExclusiveGuard(guard))
    }

    fn read(&self) -> NifResult<SharedGuard<'_, T>> {
        let guard = self.value.read().map_err(|_| lock_err())?;
        if guard.is_none() {
            return Err(closed_err(self.label));
        }

        Ok(SharedGuard(guard))
    }

    // Release is infallible and idempotent, so recover a poisoned lock.
    pub fn close(&self) {
        let mut guard = self.value.write().unwrap_or_else(|e| e.into_inner());
        *guard = None;
    }

    // Like `close`, this must remain infallible after lock poisoning.
    pub fn is_closed(&self) -> bool {
        self.value
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .is_none()
    }
}

// Catch inside the guard's scope so it drops without a panic in flight and the
// resource lock remains usable. `AssertUnwindSafe` deliberately keeps the value.
fn contain_panic<R>(f: impl FnOnce() -> NifResult<R>) -> NifResult<R> {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|payload| Err(panic_err(&*payload)))
}

pub struct ExclusiveGuard<'a, T>(RwLockWriteGuard<'a, Option<T>>);

impl<T> Deref for ExclusiveGuard<'_, T> {
    type Target = T;

    fn deref(&self) -> &Self::Target {
        // Safe to unwrap: `Closable::lock` rejects a closed value, and the guard
        // holds the lock for its whole lifetime, so it cannot be closed here.
        self.0.as_ref().expect("guard implies an open resource")
    }
}

impl<T> DerefMut for ExclusiveGuard<'_, T> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.0.as_mut().expect("guard implies an open resource")
    }
}

pub struct SharedGuard<'a, T>(RwLockReadGuard<'a, Option<T>>);

impl<T> Deref for SharedGuard<'_, T> {
    type Target = T;

    fn deref(&self) -> &Self::Target {
        self.0.as_ref().expect("guard implies an open resource")
    }
}

#[cfg(test)]
mod tests {
    use std::{sync::mpsc, thread, time::Duration};

    use super::*;

    const TIMEOUT: Duration = Duration::from_secs(5);

    #[test]
    fn two_with_read_calls_overlap() {
        let closable = &Closable::new("Test", 0_u8);
        let (tx_a, rx_a) = mpsc::channel();
        let (tx_b, rx_b) = mpsc::channel();

        // Each thread owns one end of each channel (a `Receiver` is `Send` but
        // not `Sync`), and flattens its result to a plain `bool` before joining,
        // since `rustler::Error` is not `Send` either.
        thread::scope(|scope| {
            let a = scope.spawn(move || {
                closable
                    .with_read(|_| {
                        let _ = tx_a.send(());
                        Ok(rx_b.recv_timeout(TIMEOUT).is_ok())
                    })
                    .unwrap_or(false)
            });
            let b = scope.spawn(move || {
                closable
                    .with_read(|_| {
                        let _ = tx_b.send(());
                        Ok(rx_a.recv_timeout(TIMEOUT).is_ok())
                    })
                    .unwrap_or(false)
            });

            assert!(
                a.join().expect("thread a"),
                "reader A never saw reader B inside the guard"
            );
            assert!(
                b.join().expect("thread b"),
                "reader B never saw reader A inside the guard"
            );
        });
    }

    #[test]
    fn with_lock_excludes_a_concurrent_reader() {
        const QUIET: Duration = Duration::from_millis(250);

        let closable = &Closable::new("Test", 0_u8);
        let (go_tx, go_rx) = mpsc::channel();
        let (entered_tx, entered_rx) = mpsc::channel();

        thread::scope(|scope| {
            let reader = scope.spawn(move || {
                if go_rx.recv_timeout(TIMEOUT).is_err() {
                    return false;
                }

                closable
                    .with_read(|_| {
                        let _ = entered_tx.send(());
                        Ok(())
                    })
                    .is_ok()
            });

            // Matched rather than unwrapped: `rustler::Error` is neither `Send`
            // nor `Debug`, so it cannot be carried out of a thread or named by
            // `expect`.
            let Ok(entered_while_held) = closable.with_lock(|_| {
                let _ = go_tx.send(());
                Ok(entered_rx.recv_timeout(QUIET).is_ok())
            }) else {
                panic!("exclusive access")
            };

            assert!(
                !entered_while_held,
                "a reader entered while the exclusive guard was held"
            );
            assert!(
                entered_rx.recv_timeout(TIMEOUT).is_ok(),
                "the reader never ran after the exclusive guard was released"
            );
            assert!(reader.join().expect("reader thread"), "shared access");
        });
    }

    #[test]
    fn an_unwind_caught_inside_the_guard_scope_does_not_poison() {
        let lock = RwLock::new(Some(0));

        {
            let mut guard = lock.write().expect("fresh lock");
            let caught = catch_unwind(AssertUnwindSafe(|| {
                *guard = Some(1);
                panic!("boom");
            }));
            assert!(caught.is_err());
        }

        assert!(!lock.is_poisoned());
        assert_eq!(*lock.write().expect("lock survives the panic"), Some(1));
    }

    #[test]
    fn an_unwind_through_the_guard_poisons() {
        let lock = RwLock::new(Some(0));

        let escaped = catch_unwind(AssertUnwindSafe(|| {
            let _guard = lock.write().expect("fresh lock");
            panic!("boom");
        }));

        assert!(escaped.is_err());
        assert!(lock.is_poisoned());
    }

    fn poison<T>(closable: &Closable<T>) {
        let escaped = catch_unwind(AssertUnwindSafe(|| {
            let _guard = closable.value.write().expect("fresh lock");
            panic!("poisoning on purpose");
        }));

        assert!(escaped.is_err());
        assert!(closable.value.is_poisoned(), "the lock was not poisoned");
    }

    #[test]
    fn close_recovers_a_poisoned_lock() {
        let closable = Closable::new("Test", 0_u8);
        poison(&closable);

        closable.close();

        assert!(closable.is_closed());
    }

    #[test]
    fn is_closed_recovers_a_poisoned_lock() {
        let open = Closable::new("Test", 0_u8);
        poison(&open);
        assert!(!open.is_closed(), "an open handle reported itself closed");

        let closed = Closable::new("Test", 0_u8);
        closed.close();
        poison(&closed);
        assert!(closed.is_closed(), "a closed handle reported itself open");
    }

    #[test]
    fn close_is_idempotent() {
        let closable = Closable::new("Test", 0_u8);

        closable.close();
        closable.close();

        assert!(closable.is_closed());
    }
}
