// The bounded store behind both diagnostic feeds: the log capture in
// `logging.rs` and the structured-warning buffers in `warnings.rs`.

use std::collections::VecDeque;

// Bounds retained diagnostics when callers never drain them; keeps the newest entries.
pub(crate) const MAX_BUFFERED: usize = 4096;

// Drains return retained entries and reset the drop count together.
pub(crate) struct Ring<T> {
    entries: VecDeque<T>,
    dropped: usize,
}

impl<T> Ring<T> {
    pub(crate) const fn new() -> Self {
        Self {
            entries: VecDeque::new(),
            dropped: 0,
        }
    }

    pub(crate) fn push(&mut self, entry: T) {
        if self.entries.len() >= MAX_BUFFERED {
            self.entries.pop_front();
            self.dropped += 1;
        }

        self.entries.push_back(entry);
    }

    pub(crate) fn len(&self) -> usize {
        self.entries.len()
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = &T> {
        self.entries.iter()
    }

    pub(crate) fn take_dropped(&mut self) -> usize {
        std::mem::take(&mut self.dropped)
    }

    pub(crate) fn take(&mut self) -> (Vec<T>, usize) {
        let entries = std::mem::take(&mut self.entries).into();
        let dropped = self.take_dropped();

        (entries, dropped)
    }

    pub(crate) fn clear(&mut self) {
        self.entries.clear();
        self.dropped = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_is_bounded_and_drops_oldest_first() {
        let mut ring = Ring::new();
        for i in 0..(MAX_BUFFERED + 10) {
            ring.push(i);
        }
        assert_eq!(ring.len(), MAX_BUFFERED);

        let (entries, dropped) = ring.take();
        assert_eq!(entries.len(), MAX_BUFFERED);
        assert_eq!(dropped, 10);
        assert_eq!(entries[0], 10);

        let (entries, dropped) = ring.take();
        assert!(entries.is_empty());
        assert_eq!(dropped, 0);
    }
}
