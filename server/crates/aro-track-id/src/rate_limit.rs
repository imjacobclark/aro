//! A minimal async rate limiter that spaces out calls at a fixed interval.
//!
//! Deliberately not a token-bucket-with-bursting implementation: the identification
//! queue processes jobs one at a time on a single worker (see `queue.rs`), so there is
//! never more than one caller waiting on a given limiter. A fixed minimum spacing
//! between calls is enough to stay under AcoustID's (~3 req/s) and MusicBrainz's (~1
//! req/s) documented limits without pulling in a token-bucket crate for a single
//! consumer.

use std::time::Duration;
use tokio::{sync::Mutex, time::Instant};

pub struct RateLimiter {
    interval: Duration,
    earliest_next: Mutex<Instant>,
}

impl RateLimiter {
    pub fn per_second(max_requests_per_second: f64) -> Self {
        Self {
            interval: Duration::from_secs_f64(1.0 / max_requests_per_second),
            earliest_next: Mutex::new(Instant::now()),
        }
    }

    /// Waits until it's safe to issue the next call, then reserves the following slot.
    pub async fn acquire(&self) {
        loop {
            let wait = {
                let mut earliest_next = self.earliest_next.lock().await;
                let now = Instant::now();
                if now >= *earliest_next {
                    *earliest_next = now + self.interval;
                    None
                } else {
                    Some(*earliest_next - now)
                }
            };
            match wait {
                None => return,
                Some(duration) => tokio::time::sleep(duration).await,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn spaces_calls_at_least_one_interval_apart() {
        let limiter = RateLimiter::per_second(2.0); // 500ms interval
        let start = Instant::now();

        limiter.acquire().await;
        let first = Instant::now();
        limiter.acquire().await;
        let second = Instant::now();
        limiter.acquire().await;
        let third = Instant::now();

        assert!(first - start < Duration::from_millis(50));
        assert!(second - first >= Duration::from_millis(500));
        assert!(third - second >= Duration::from_millis(500));
    }
}
