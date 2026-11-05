use std::{
    cell::Cell,
    panic::{self, AssertUnwindSafe},
    sync::atomic::{AtomicBool, Ordering},
};

// Windows commits the whole segment rather than reserving it.
#[cfg(not(windows))]
const SEGMENT_SIZE: usize = 256 * 1024 * 1024;
#[cfg(windows)]
const SEGMENT_SIZE: usize = 32 * 1024 * 1024;

thread_local! {
    static ON_SEGMENT: Cell<bool> = const { Cell::new(false) };
}

// Set once allocation fails, so its panic is reported once, not per call.
static UNAVAILABLE: AtomicBool = AtomicBool::new(false);

// Keeps work on the calling thread; falls back to its current stack if allocation fails.
pub(crate) fn on_deep_stack<R>(work: impl FnOnce() -> R) -> R {
    if ON_SEGMENT.get() || UNAVAILABLE.load(Ordering::Relaxed) {
        return work();
    }

    let mut work = Some(work);
    let grown = panic::catch_unwind(AssertUnwindSafe(|| {
        stacker::grow(SEGMENT_SIZE, || {
            let _segment = OnSegment::enter();
            work.take().expect("work runs once")()
        })
    }));

    match grown {
        Ok(result) => result,
        // Untaken work means allocation failed; otherwise propagate the work's panic.
        Err(payload) => match work.take() {
            Some(work) => {
                UNAVAILABLE.store(true, Ordering::Relaxed);
                work()
            }
            None => panic::resume_unwind(payload),
        },
    }
}

pub(crate) fn drop_deep<T>(value: T) {
    on_deep_stack(|| drop(value));
}

struct OnSegment;

impl OnSegment {
    fn enter() -> Self {
        ON_SEGMENT.set(true);
        OnSegment
    }
}

impl Drop for OnSegment {
    fn drop(&mut self) {
        ON_SEGMENT.set(false);
    }
}
