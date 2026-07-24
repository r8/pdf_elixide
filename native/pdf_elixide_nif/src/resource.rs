use std::{
    ops::{Deref, DerefMut},
    sync::{RwLock, RwLockReadGuard, RwLockWriteGuard},
};

use rustler::NifResult;

use crate::error::{closed_err, lock_err};

/// A native value held behind a BEAM resource handle, with an explicit release.
///
/// The value is normally dropped when the BEAM garbage-collects the handle;
/// `close` drops it immediately instead, which matters for long-lived processes
/// that open many documents (the Rust-side buffers are invisible to the BEAM's
/// memory accounting, so nothing pressures it to collect them). Once closed, the
/// `Option` is `None` and every accessor reports `:closed` rather than touching
/// freed data.
///
/// Access is exclusive via [`Closable::lock`] (documents and editors, whose
/// upstream methods need `&mut`) or shared via [`Closable::read`] (images and
/// fonts, which are only ever read).
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

    /// Takes exclusive access to the value, erroring with `:closed` if it has
    /// been released or `:lock_poisoned` if the lock is poisoned.
    pub fn lock(&self) -> NifResult<ExclusiveGuard<'_, T>> {
        let guard = self.value.write().map_err(|_| lock_err())?;
        if guard.is_none() {
            return Err(closed_err(self.label));
        }

        Ok(ExclusiveGuard(guard))
    }

    /// Takes shared access to the value, with the same error cases as
    /// [`Closable::lock`].
    pub fn read(&self) -> NifResult<SharedGuard<'_, T>> {
        let guard = self.value.read().map_err(|_| lock_err())?;
        if guard.is_none() {
            return Err(closed_err(self.label));
        }

        Ok(SharedGuard(guard))
    }

    /// Drops the value now, freeing its memory. Idempotent, and infallible: a
    /// poisoned lock is recovered, since releasing memory is safe regardless of
    /// what a previous panic left behind.
    pub fn close(&self) {
        let mut guard = self.value.write().unwrap_or_else(|e| e.into_inner());
        *guard = None;
    }

    pub fn is_closed(&self) -> bool {
        self.value
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .is_none()
    }
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
