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
/// **Access is shared by default.** [`Closable::with_read`] serves documents,
/// images, fonts and tables, so one `%Document{}` handle passed to several BEAM
/// processes extracts concurrently instead of queueing. That is sound because
/// upstream asserts `PdfDocument: Send + Sync`, exposes no `&mut self` method on
/// it, and keeps every cache behind a `Mutex` or an atomic — though that same
/// `load_lock` serializes *cold* object loads, so only warm cache hits run fully
/// parallel. One field is not a cache: `mc_actualtext_mcids` is per-invocation
/// extraction scratch keyed by page index, so two extractions of one page can
/// cross-contaminate. Unrepairable here (the field is `pub(crate)`) and not
/// caused by concurrency — two sequential calls do it too — so it is documented
/// for callers in `guides/concurrency.md`.
///
/// [`Closable::with_lock`] is exclusive, and is for exactly three things: the
/// editor, whose `DocumentEditor` methods take `&mut self`;
/// `document_authenticate`, whose object-cache invalidation must not be
/// straddled by a reader; and `document_clear_search_index`, whose release a
/// concurrent search would otherwise undo. Both accessors run the caller's work
/// in a closure so the guard never escapes — see [`contain_panic`] for why that
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
    ///
    /// Exclusive means it drains every in-flight reader and blocks every new
    /// one, so reach for it only when the value genuinely needs `&mut`, or when
    /// the effect must be atomic against readers. Everything else uses
    /// [`Closable::with_read`].
    pub fn with_lock<R>(&self, f: impl FnOnce(&mut T) -> NifResult<R>) -> NifResult<R> {
        // The guard is bound here, in the caller's frame, rather than inside the
        // closure — that is what keeps a panic from poisoning the lock (see
        // `contain_panic`).
        let mut guard = self.lock()?;

        contain_panic(|| f(&mut guard))
    }

    /// Runs `f` with shared access to the value, with the same error cases as
    /// [`Closable::with_lock`].
    ///
    /// The default, and what lets any number of threads run `f` on one handle at
    /// once — the reason a single document serves concurrent extractions. It
    /// still excludes [`Closable::close`], which is what keeps closing a handle
    /// safe while calls are in flight.
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
    /// It takes the lock exclusively, so it waits for *every* in-flight
    /// [`Closable::with_read`] to drain — and there can be many at once — as
    /// well as an in-flight [`Closable::with_lock`]: "now" means as soon as the
    /// handle is idle, not preemptively. That wait is why every `*_close` NIF is
    /// dirty-scheduled.
    pub fn close(&self) {
        let mut guard = self.value.write().unwrap_or_else(|e| e.into_inner());
        *guard = None;
    }

    /// Whether the value has been released, recovering a poisoned lock the same
    /// way [`Closable::close`] does. It takes the read lock, so it runs
    /// alongside other readers but still waits behind an exclusive access —
    /// `close`, or an editor call, or `document_authenticate`, each of which
    /// waits in turn for the readers ahead of it. The rule did not soften with
    /// the switch to shared reads: the `*_closed` NIFs stay dirty-scheduled,
    /// cheap as the check looks.
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
/// This exists to protect the lock, not just the error message. `std` records
/// poisoning only when a panic is in flight as the guard drops, so catching the
/// unwind *inside* the guard's scope — which is why the callers above bind the
/// guard first — lets the guard drop cleanly and leaves the lock usable.
/// Without it, one panic anywhere in `pdf_oxide` would make every later call on
/// that handle report `:lock_poisoned` forever, with only `close` still working.
///
/// `AssertUnwindSafe` is the deliberate trade-off: the value stays alive, so a
/// panic partway through a mutation can leave upstream state partially updated,
/// and under [`Closable::with_read`] that half-updated value is visible to
/// concurrent readers too. What makes it acceptable is what the interior
/// mutability is — `Mutex`-guarded caches whose worst case is a stale or missing
/// entry, reached through upstream's own `lock_or_recover`, so a poisoned inner
/// mutex is recovered rather than propagated. Still better than a permanently
/// bricked handle, and the `:panic` error tells the caller to close and reopen
/// if it recurs.
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
    use std::{sync::mpsc, thread, time::Duration};

    use super::*;

    /// Generous: these bound a failure, not a measurement.
    const TIMEOUT: Duration = Duration::from_secs(5);

    /// The point of the read/write split: two [`Closable::with_read`] calls on
    /// one handle are genuinely inside the closure at the same time. If this
    /// ever fails, every document NIF has quietly gone back to serializing.
    ///
    /// Deterministic rather than timed — each thread announces its entry and
    /// then waits for the other's announcement *without leaving its closure*, so
    /// both receives can only return if both guards are held at once. Were
    /// `with_read` exclusive the second thread would block on acquisition and
    /// the first would time out: it degrades to a failure, never to a hang.
    ///
    /// Only success paths run here, which is what makes this testable without a
    /// BEAM: the error paths build atoms, `Ok` does not. For the same reason
    /// nothing inside a guard may `panic` — `contain_panic` would catch it and
    /// reach for an atom, aborting the test process instead of failing the test
    /// — so every assertion is made after the closure returns.
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

    /// The other half: [`Closable::with_lock`] still excludes a concurrent
    /// reader. That is what `document_authenticate` rests on — it is left
    /// exclusive so no extraction can straddle upstream's object-cache
    /// invalidation — and what `close` rests on.
    ///
    /// The reader is released from *inside* the exclusive guard rather than
    /// spawned and hoped about: it waits for a go-ahead before it even attempts
    /// `with_read`, so the ordering under test — writer holds, reader tries — is
    /// established rather than raced.
    ///
    /// This one proves an *absence*, so it is the only place in the crate with a
    /// wait in it. The asymmetry is deliberate and safe: a machine too loaded to
    /// schedule the reader within `QUIET` produces a spurious *pass*, never a
    /// spurious failure. The half that can fail — the reader completing once the
    /// exclusive guard drops — is deterministic.
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

    /// Pins the `std` guarantee `contain_panic` is built on: an unwind caught
    /// inside the guard's scope leaves the lock unpoisoned, because the guard is
    /// dropped with no panic in flight. If this ever fails, the containment above
    /// is silently doing nothing — don't relax it, rethink the design.
    ///
    /// This one goes through a bare `RwLock` rather than a `Closable`: the
    /// containment being pinned is `std`'s, and the two tests above already
    /// cover the accessors themselves. What no test here can reach is either
    /// accessor's *error* path — `:closed`, `:lock_poisoned` and `:panic` all
    /// build atoms, which need a live BEAM.
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

    /// Poisons a [`Closable`]'s lock the only way `std` allows: unwind *through*
    /// a held write guard, as `an_unwind_through_the_guard_poisons` establishes.
    ///
    /// Reaches the private `value` field directly, because nothing in the public
    /// surface can do this — which is the whole point of the two tests below.
    /// The panic is contained here and its payload discarded; the message it
    /// prints to stderr is expected.
    fn poison<T>(closable: &Closable<T>) {
        let escaped = catch_unwind(AssertUnwindSafe(|| {
            let _guard = closable.value.write().expect("fresh lock");
            panic!("poisoning on purpose");
        }));

        assert!(escaped.is_err());
        assert!(closable.value.is_poisoned(), "the lock was not poisoned");
    }

    /// [`Closable::close`] promises to be infallible, recovering a poisoned lock
    /// rather than reporting one, on the grounds that releasing memory is safe
    /// whatever a previous panic left behind. It is one of exactly two places in
    /// `Closable` that recover instead of erroring.
    ///
    /// `contain_panic` makes poisoning unreachable through the crate's own
    /// surface, so this is defence in depth, pinned the way `MAX_OUTLINE_DEPTH`
    /// is: the recovery is invisible from every route, so its removal would be
    /// silent. Deliberately not asserted alongside it: that `with_read` on the
    /// same poisoned lock reports `:lock_poisoned` — that path builds an atom,
    /// which would abort the test process rather than fail the test.
    #[test]
    fn close_recovers_a_poisoned_lock() {
        let closable = Closable::new("Test", 0_u8);
        poison(&closable);

        closable.close();

        assert!(closable.is_closed());
    }

    /// The other recovering accessor, checked on its own: reading whether a
    /// handle is closed must survive a poisoned lock too, and must still answer
    /// truthfully rather than defaulting to one verdict.
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

    /// `close` is documented as idempotent, and the `*_close` NIFs return `:ok`
    /// unconditionally on the strength of that. Closing twice must not panic on
    /// the second `None`.
    #[test]
    fn close_is_idempotent() {
        let closable = Closable::new("Test", 0_u8);

        closable.close();
        closable.close();

        assert!(closable.is_closed());
    }
}
