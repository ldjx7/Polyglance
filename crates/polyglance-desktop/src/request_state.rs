use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

#[derive(Default)]
pub struct RequestTracker {
    generation: AtomicU64,
    remaining: AtomicUsize,
}

impl RequestTracker {
    pub fn start(&self, task_count: usize) -> u64 {
        let id = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
        self.remaining.store(task_count, Ordering::Release);
        id
    }

    pub fn is_current(&self, id: u64) -> bool {
        self.generation.load(Ordering::Acquire) == id
    }

    /// Returns Some(true) only when the final task of the current request finishes.
    pub fn finish(&self, id: u64) -> Option<bool> {
        if !self.is_current(id) {
            return None;
        }
        let previous = self
            .remaining
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                count.checked_sub(1)
            })
            .ok()?;
        Some(previous == 1)
    }

    pub fn cancel(&self) {
        self.generation.fetch_add(1, Ordering::AcqRel);
        self.remaining.store(0, Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stale_results_cannot_finish_a_new_request() {
        let tracker = RequestTracker::default();
        let old = tracker.start(2);
        let current = tracker.start(2);
        assert_eq!(tracker.finish(old), None);
        assert_eq!(tracker.finish(current), Some(false));
        assert_eq!(tracker.finish(current), Some(true));
        assert_eq!(tracker.finish(current), None);
    }

    #[test]
    fn cancellation_invalidates_pending_results() {
        let tracker = RequestTracker::default();
        let id = tracker.start(1);
        tracker.cancel();
        assert_eq!(tracker.finish(id), None);
    }
}
