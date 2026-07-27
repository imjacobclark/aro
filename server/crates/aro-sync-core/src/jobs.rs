use aro_sync_protocol::{JobState, SyncJob};
use parking_lot::RwLock;
use std::{collections::HashMap, sync::Arc};
use uuid::Uuid;

#[derive(Clone, Default)]
pub struct JobRegistry(Arc<RwLock<HashMap<Uuid, SyncJob>>>);

impl JobRegistry {
    pub fn create(&self, kind: impl Into<String>, total_units: u64) -> SyncJob {
        let job = SyncJob {
            job_id: Uuid::new_v4(),
            kind: kind.into(),
            state: JobState::Pending,
            completed_units: 0,
            total_units,
            error: None,
        };
        self.0.write().insert(job.job_id, job.clone());
        job
    }

    pub fn get(&self, id: Uuid) -> Option<SyncJob> {
        self.0.read().get(&id).cloned()
    }

    pub fn cancel(&self, id: Uuid) -> Option<SyncJob> {
        let mut jobs = self.0.write();
        let job = jobs.get_mut(&id)?;
        if !matches!(job.state, JobState::Completed | JobState::Failed) {
            job.state = JobState::Cancelled;
        }
        Some(job.clone())
    }

    pub fn start(&self, id: Uuid) -> Option<SyncJob> {
        let mut jobs = self.0.write();
        let job = jobs.get_mut(&id)?;
        if job.state == JobState::Pending {
            job.state = JobState::Running;
        }
        Some(job.clone())
    }

    pub fn complete(&self, id: Uuid) -> Option<SyncJob> {
        let mut jobs = self.0.write();
        let job = jobs.get_mut(&id)?;
        if !matches!(job.state, JobState::Cancelled | JobState::Failed) {
            job.state = JobState::Completed;
            job.completed_units = job.total_units;
        }
        Some(job.clone())
    }
}
