// Buffers `pdf_oxide` log records until `PdfElixide.Native.Wrap.call/1` drains
// them. Sending directly would panic because records are emitted on dirty
// scheduler threads.

use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Mutex, OnceLock,
};

use log::{Level, LevelFilter, Log, Metadata, Record};
use rustler::{Atom, Encoder, Env, NifResult, Term};

use crate::atoms;

// Bounds the buffer for a caller who enables capture and then never calls
// through `Wrap.call/1` again, so nothing drains it.
const MAX_BUFFERED: usize = 4096;

struct Buffered {
    level: Level,
    target: String,
    message: String,
}

// Records and the drop count move together, so a drained batch always carries
// the count of what was dropped from that same batch.
#[derive(Default)]
struct Capture {
    records: Vec<Buffered>,
    dropped: usize,
}

static CAPTURE: Mutex<Capture> = Mutex::new(Capture {
    records: Vec::new(),
    dropped: 0,
});
static ENABLED: AtomicBool = AtomicBool::new(false);
// Mirrors `CAPTURE.records.len()`, written under the lock and read without it
// by `log_pending`, which runs on every wrapped call and must not contend.
static PENDING: AtomicUsize = AtomicUsize::new(0);
static LOGGER: OnceLock<()> = OnceLock::new();

struct BufferLogger;

impl Log for BufferLogger {
    fn enabled(&self, _metadata: &Metadata) -> bool {
        ENABLED.load(Ordering::Relaxed)
    }

    fn log(&self, record: &Record) {
        if !self.enabled(record.metadata()) {
            return;
        }

        // Dropping the record beats propagating a poisoned-lock panic out of a
        // log call in the middle of unrelated extraction work.
        let Ok(mut capture) = CAPTURE.lock() else {
            return;
        };

        // Re-checked under the lock: the load above may have raced a disable
        // that already cleared the buffer, and this push would outlive it.
        if !ENABLED.load(Ordering::Relaxed) {
            return;
        }

        if capture.records.len() >= MAX_BUFFERED {
            capture.records.remove(0);
            capture.dropped += 1;
        }

        capture.records.push(Buffered {
            level: record.level(),
            target: record.target().to_string(),
            message: record.args().to_string(),
        });
        PENDING.store(capture.records.len(), Ordering::Relaxed);
    }

    fn flush(&self) {}
}

fn level_atom(level: Level) -> Atom {
    match level {
        Level::Error => atoms::error(),
        Level::Warn => atoms::warn(),
        Level::Info => atoms::info(),
        Level::Debug => atoms::debug(),
        Level::Trace => atoms::trace(),
    }
}

fn filter_of(level: Atom) -> Option<LevelFilter> {
    if level == atoms::off() {
        Some(LevelFilter::Off)
    } else if level == atoms::error() {
        Some(LevelFilter::Error)
    } else if level == atoms::warn() {
        Some(LevelFilter::Warn)
    } else if level == atoms::info() {
        Some(LevelFilter::Info)
    } else if level == atoms::debug() {
        Some(LevelFilter::Debug)
    } else if level == atoms::trace() {
        Some(LevelFilter::Trace)
    } else {
        None
    }
}

// Dirty because disabling frees the whole buffer, up to `MAX_BUFFERED` pairs of
// heap strings.
#[rustler::nif(schedule = "DirtyCpu")]
fn log_set_level(level: Atom) -> NifResult<Atom> {
    let Some(filter) = filter_of(level) else {
        return Err(rustler::Error::BadArg);
    };

    // On first use, not at load: a caller who never enables capture never has a
    // global logger imposed on the process.
    LOGGER.get_or_init(|| {
        let _ = log::set_logger(&BufferLogger);
    });

    // Stored before the buffer is cleared below, so a producer blocked on the
    // lock sees the disable when it wakes rather than pushing past the clear.
    ENABLED.store(filter != LevelFilter::Off, Ordering::Relaxed);
    log::set_max_level(filter);

    if filter == LevelFilter::Off {
        if let Ok(mut capture) = CAPTURE.lock() {
            *capture = Capture::default();
        }
        PENDING.store(0, Ordering::Relaxed);
    }

    Ok(atoms::ok())
}

// Dirty because it encodes the whole buffer, and neither the record count nor
// each record's byte length is bounded by anything a caller controls.
#[rustler::nif(schedule = "DirtyCpu")]
fn log_drain(env: Env<'_>) -> NifResult<Term<'_>> {
    let taken = match CAPTURE.lock() {
        Ok(mut capture) => {
            PENDING.store(0, Ordering::Relaxed);
            std::mem::take(&mut *capture)
        }
        Err(_) => Capture::default(),
    };

    let records: Vec<Term<'_>> = taken
        .records
        .into_iter()
        .map(|record| {
            (
                level_atom(record.level),
                record.target.as_str(),
                record.message.as_str(),
            )
                .encode(env)
        })
        .collect();

    Ok((records, taken.dropped).encode(env))
}

// Must stay off a dirty scheduler: it runs after every wrapped call, so it has
// to cost less than the dirty dispatch it decides against.
#[rustler::nif]
fn log_pending() -> usize {
    PENDING.load(Ordering::Relaxed)
}

#[rustler::nif]
fn log_enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use super::*;

    // The buffer, the enable flag and the drop counter are process-global, so
    // parallel tests would clear each other's state. Every test holds this.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn reset() {
        *CAPTURE.lock().unwrap() = Capture::default();
        PENDING.store(0, Ordering::Relaxed);
    }

    fn push(message: &str) {
        BufferLogger.log(
            &Record::builder()
                .args(format_args!("{}", message))
                .level(Level::Warn)
                .target("test")
                .build(),
        );
    }

    #[test]
    fn disabled_logger_buffers_nothing() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset();
        ENABLED.store(false, Ordering::Relaxed);

        push("ignored");

        assert!(CAPTURE.lock().unwrap().records.is_empty());
        assert_eq!(PENDING.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn a_record_racing_a_disable_is_dropped_under_the_lock() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset();

        // Stands in for a producer that read `ENABLED` as true, then blocked on
        // the lock while a disable cleared the buffer and flipped the flag.
        ENABLED.store(false, Ordering::Relaxed);
        push("raced a disable");

        assert!(CAPTURE.lock().unwrap().records.is_empty());
    }

    #[test]
    fn buffer_is_bounded_and_carries_its_own_drop_count() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset();
        ENABLED.store(true, Ordering::Relaxed);

        for i in 0..(MAX_BUFFERED + 10) {
            push(&format!("record {i}"));
        }
        ENABLED.store(false, Ordering::Relaxed);

        let taken = std::mem::take(&mut *CAPTURE.lock().unwrap());
        assert_eq!(taken.records.len(), MAX_BUFFERED);
        assert_eq!(taken.dropped, 10);
        // The oldest went, not the newest: a truncated capture keeps the
        // records nearest the failure being diagnosed.
        assert_eq!(taken.records[0].message, "record 10");
    }

    #[test]
    fn pending_tracks_the_buffer() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset();
        ENABLED.store(true, Ordering::Relaxed);

        push("one");
        push("two");
        assert_eq!(PENDING.load(Ordering::Relaxed), 2);

        ENABLED.store(false, Ordering::Relaxed);
        reset();
        assert_eq!(PENDING.load(Ordering::Relaxed), 0);
    }
}
