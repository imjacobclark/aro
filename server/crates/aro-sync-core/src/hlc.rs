use aro_sync_protocol::HybridTimestamp;
use uuid::Uuid;

#[derive(Clone, Debug)]
pub struct HybridClock {
    device_id: Uuid,
    last_physical: i64,
    logical: u32,
}

impl HybridClock {
    pub fn new(device_id: Uuid) -> Self {
        Self {
            device_id,
            last_physical: 0,
            logical: 0,
        }
    }

    pub fn tick(&mut self, now_millis: i64) -> HybridTimestamp {
        if now_millis > self.last_physical {
            self.last_physical = now_millis;
            self.logical = 0;
        } else {
            self.logical = self.logical.saturating_add(1);
        }
        self.current()
    }

    pub fn observe(&mut self, remote: &HybridTimestamp, now_millis: i64) -> HybridTimestamp {
        let physical = now_millis
            .max(self.last_physical)
            .max(remote.physical_millis);
        self.logical = if physical == self.last_physical && physical == remote.physical_millis {
            self.logical.max(remote.logical).saturating_add(1)
        } else if physical == self.last_physical {
            self.logical.saturating_add(1)
        } else if physical == remote.physical_millis {
            remote.logical.saturating_add(1)
        } else {
            0
        };
        self.last_physical = physical;
        self.current()
    }

    fn current(&self) -> HybridTimestamp {
        HybridTimestamp {
            physical_millis: self.last_physical,
            logical: self.logical,
            device_id: self.device_id,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clock_is_monotonic_when_wall_clock_moves_backwards() {
        let mut clock = HybridClock::new(Uuid::nil());
        let first = clock.tick(100);
        let second = clock.tick(50);
        assert!(second > first);
        assert_eq!(second.physical_millis, 100);
    }

    #[test]
    fn observed_clock_orders_after_remote() {
        let remote = HybridTimestamp {
            physical_millis: 200,
            logical: 4,
            device_id: Uuid::nil(),
        };
        let mut clock = HybridClock::new(Uuid::new_v4());
        assert!(clock.observe(&remote, 100) > remote);
    }
}
