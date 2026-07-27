use std::{
    ops::{Deref, DerefMut},
    panic::{catch_unwind, AssertUnwindSafe},
    sync::{RwLock, RwLockReadGuard, RwLockWriteGuard},
};

use rustler::NifResult;

use crate::error::{closed_err, lock_err, panic_err};

/// A native value held behind a BEAM resource handle, with an explicit release.
///
/// The value is normally dropped when the BEAM garbage-collects the handle;
/// `close` drops it immediately instead, which matters for long-lived processes
/// that open many documents (the Rust-side buffers are invisible to the BEAM's
/// memory accounting, so nothing pressures it to collect them). Once closed, the
/// `Option` is `None` and every accessor reports `:closed` rather than touching
/// freed data.
///
/// Access is exclusive via [`Closable::with_lock`] (documents and editors, whose
/// upstream methods need `&mut`) or shared via [`Closable::with_read`] (images,
/// fonts and tables, which are only ever read). Both run the caller's work in a
/// closure so the guard never escapes — see [`contain_panic`] for why that
/// matters.
pub struct Closable<T> {
    /// Name used in the `:closed` error message, e.g. `"Document"`.
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

    /// Runs `f` with exclusive access to the value, erroring with `:closed` if it
    /// has been released, `:lock_poisoned` if the lock is poisoned, or `:panic`
    /// if `f` panics.
    pub fn with_lock<R>(&self, f: impl FnOnce(&mut T) -> NifResult<R>) -> NifResult<R> {
        // The guard is bound here, in the caller's frame, rather than inside the
        // closure — that is what keeps a panic from poisoning the lock (see
        // `contain_panic`).
        let mut guard = self.lock()?;

        contain_panic(|| f(&mut guard))
    }

    /// Runs `f` with shared access to the value, with the same error cases as
    /// [`Closable::with_lock`].
    pub fn with_read<R>(&self, f: impl FnOnce(&T) -> NifResult<R>) -> NifResult<R> {
        let guard = self.read()?;

        contain_panic(|| f(&guard))
    }

    /// Takes exclusive access to the value, erroring with `:closed` if it has
    /// been released or `:lock_poisoned` if the lock is poisoned. Private: a
    /// guard must not outlive [`Closable::with_lock`]'s panic containment.
    fn lock(&self) -> NifResult<ExclusiveGuard<'_, T>> {
        let guard = self.value.write().map_err(|_| lock_err())?;
        if guard.is_none() {
            return Err(closed_err(self.label));
        }

        Ok(ExclusiveGuard(guard))
    }

    /// Takes shared access to the value, with the same error cases as
    /// [`Closable::lock`]. Private, for the same reason.
    fn read(&self) -> NifResult<SharedGuard<'_, T>> {
        let guard = self.value.read().map_err(|_| lock_err())?;
        if guard.is_none() {
            return Err(closed_err(self.label));
        }

        Ok(SharedGuard(guard))
    }

    /// Drops the value now, freeing its memory. Idempotent, and infallible: a
    /// poisoned lock is recovered, since releasing memory is safe regardless of
    /// what a previous panic left behind.
    ///
    /// It takes the lock like any other access, so an in-flight
    /// [`Closable::with_lock`] or [`Closable::with_read`] on the same handle
    /// delays it until that call returns: "now" means as soon as the handle is
    /// idle, not preemptively. That wait is why every `*_close` NIF is
    /// dirty-scheduled.
    pub fn close(&self) {
        let mut guard = self.value.write().unwrap_or_else(|e| e.into_inner());
        *guard = None;
    }

    /// Whether the value has been released, recovering a poisoned lock the same
    /// way [`Closable::close`] does. It still takes the read lock, so an
    /// in-flight exclusive access on the same handle delays it — which is why
    /// the `*_closed` NIFs are dirty-scheduled too, cheap as the check looks.
    pub fn is_closed(&self) -> bool {
        self.value
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .is_none()
    }
}

/// Runs `f`, turning a panic into a `:panic` error instead of letting it unwind
/// out of the NIF.
///
/// This exists to protect the lock, not just the error message. `pdf_oxide` has
/// thousands of `unwrap`/`expect` call sites, so a malformed PDF can panic deep
/// inside an extraction that runs while a guard is alive. `std` records
/// poisoning only when a panic is in flight as the guard drops
/// (`std/src/sync/poison.rs`, `Flag::done`), so catching the unwind *inside* the
/// guard's scope — which is why the callers above bind the guard first — lets the
/// guard drop cleanly and leaves the lock usable. Without it, one panic would
/// make every later call on that handle report `:lock_poisoned` forever, with
/// only `close` still working.
///
/// `AssertUnwindSafe` is the deliberate trade-off: the value stays alive, so a
/// panic partway through a mutation can leave upstream state partially updated.
/// That is better than a permanently bricked handle, and the `:panic` error tells
/// the caller to close and reopen if it recurs.
fn contain_panic<R>(f: impl FnOnce() -> NifResult<R>) -> NifResult<R> {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or_else(|payload| Err(panic_err(&*payload)))
}

/// Exclusive access to an open [`Closable`], dereferencing to the value itself.
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

/// Shared access to an open [`Closable`], dereferencing to the value itself.
pub struct SharedGuard<'a, T>(RwLockReadGuard<'a, Option<T>>);

impl<T> Deref for SharedGuard<'_, T> {
    type Target = T;

    fn deref(&self) -> &Self::Target {
        self.0.as_ref().expect("guard implies an open resource")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pins the `std` guarantee `contain_panic` is built on: an unwind caught
    /// inside the guard's scope leaves the lock unpoisoned, because the guard is
    /// dropped with no panic in flight. If this ever fails, the containment above
    /// is silently doing nothing — don't relax it, rethink the design.
    ///
    /// `Closable::with_lock` itself can't be exercised here: its error path builds
    /// an atom, which needs a live BEAM.
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

    /// The mirror image, for contrast: let the same panic escape the guard's
    /// scope and the lock is poisoned for good.
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
}
