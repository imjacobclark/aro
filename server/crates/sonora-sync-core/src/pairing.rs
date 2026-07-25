use chrono::{DateTime, Duration, Utc};
use parking_lot::RwLock;
use rand::{Rng, distr::Alphanumeric};
use sha2::{Digest, Sha256};
use sonora_sync_protocol::{
    DeviceCredential, DeviceSummary, PairingStartRequest, PairingStartResponse, PairingState,
    PairingStatusResponse,
};
use std::{collections::HashMap, sync::Arc};
use subtle::ConstantTimeEq;
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PairingError {
    #[error("pairing is unavailable")]
    Unavailable,
    #[error("invalid or expired pairing code")]
    InvalidCode,
    #[error("TLS fingerprint does not match")]
    FingerprintMismatch,
    #[error("pairing request not found")]
    RequestNotFound,
}

struct Pending {
    device_id: Uuid,
    device_name: String,
    expires_at: DateTime<Utc>,
    state: PairingState,
    credential: Option<DeviceCredential>,
}

struct Device {
    summary: DeviceSummary,
    credential_hash: [u8; 32],
}

struct State {
    code: Option<String>,
    code_expires_at: DateTime<Utc>,
    pending: HashMap<Uuid, Pending>,
    devices: HashMap<Uuid, Device>,
}

#[derive(Clone)]
pub struct PairingManager {
    fingerprint: String,
    state: Arc<RwLock<State>>,
}

impl PairingManager {
    pub fn new(fingerprint: String) -> Self {
        Self {
            fingerprint,
            state: Arc::new(RwLock::new(State {
                code: None,
                code_expires_at: Utc::now(),
                pending: HashMap::new(),
                devices: HashMap::new(),
            })),
        }
    }

    pub fn open(&self, lifetime: Duration) -> String {
        let code = format!("{:06}", rand::rng().random_range(0..1_000_000));
        let mut state = self.state.write();
        state.code = Some(code.clone());
        state.code_expires_at = Utc::now() + lifetime;
        code
    }

    pub fn is_open(&self) -> bool {
        let state = self.state.read();
        state.code.is_some() && Utc::now() < state.code_expires_at
    }

    pub fn start(
        &self,
        request: PairingStartRequest,
    ) -> Result<PairingStartResponse, PairingError> {
        let mut state = self.state.write();
        let Some(code) = &state.code else {
            return Err(PairingError::Unavailable);
        };
        if Utc::now() >= state.code_expires_at || code != &request.code {
            return Err(PairingError::InvalidCode);
        }
        if request.pinned_tls_fingerprint != self.fingerprint {
            return Err(PairingError::FingerprintMismatch);
        }
        let request_id = Uuid::new_v4();
        let expires_at = state.code_expires_at;
        state.pending.insert(
            request_id,
            Pending {
                device_id: request.device_id,
                device_name: request.device_name,
                expires_at,
                state: PairingState::Pending,
                credential: None,
            },
        );
        Ok(PairingStartResponse {
            request_id,
            state: PairingState::Pending,
        })
    }

    pub fn approve(
        &self,
        request_id: Uuid,
        approve: bool,
    ) -> Result<Option<DeviceCredential>, PairingError> {
        let mut state = self.state.write();
        let pending = state
            .pending
            .get_mut(&request_id)
            .ok_or(PairingError::RequestNotFound)?;
        if Utc::now() >= pending.expires_at {
            pending.state = PairingState::Expired;
            return Ok(None);
        }
        if !approve {
            pending.state = PairingState::Rejected;
            return Ok(None);
        }
        let credential: String = rand::rng()
            .sample_iter(&Alphanumeric)
            .take(48)
            .map(char::from)
            .collect();
        let credential_hash: [u8; 32] = Sha256::digest(credential.as_bytes()).into();
        let device_id = pending.device_id;
        let device_name = pending.device_name.clone();
        let issued = DeviceCredential {
            device_id,
            credential,
        };
        pending.state = PairingState::Approved;
        pending.credential = Some(issued.clone());
        state.devices.insert(
            device_id,
            Device {
                summary: DeviceSummary {
                    device_id,
                    name: device_name,
                    paired_at: Utc::now(),
                    revoked_at: None,
                },
                credential_hash,
            },
        );
        state.code = None;
        Ok(Some(issued))
    }

    pub fn status(
        &self,
        request_id: Uuid,
        device_id: Uuid,
    ) -> Result<PairingStatusResponse, PairingError> {
        let mut state = self.state.write();
        let pending = state
            .pending
            .get_mut(&request_id)
            .ok_or(PairingError::RequestNotFound)?;
        if pending.device_id != device_id {
            return Err(PairingError::RequestNotFound);
        }
        if pending.state == PairingState::Pending && Utc::now() >= pending.expires_at {
            pending.state = PairingState::Expired;
        }
        Ok(PairingStatusResponse {
            state: pending.state.clone(),
            credential: pending.credential.clone(),
        })
    }

    pub fn authorize(&self, device_id: Uuid, credential: &str) -> bool {
        let state = self.state.read();
        let Some(device) = state.devices.get(&device_id) else {
            return false;
        };
        if device.summary.revoked_at.is_some() {
            return false;
        }
        let candidate: [u8; 32] = Sha256::digest(credential.as_bytes()).into();
        device.credential_hash.ct_eq(&candidate).into()
    }

    pub fn devices(&self) -> Vec<DeviceSummary> {
        self.state
            .read()
            .devices
            .values()
            .map(|d| d.summary.clone())
            .collect()
    }

    pub fn revoke(&self, device_id: Uuid) -> bool {
        let mut state = self.state.write();
        let Some(device) = state.devices.get_mut(&device_id) else {
            return false;
        };
        device.summary.revoked_at = Some(Utc::now());
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_pinned_approved_devices_are_authorized_and_revocation_is_immediate() {
        let manager = PairingManager::new("fingerprint".into());
        let code = manager.open(Duration::minutes(1));
        let device_id = Uuid::new_v4();
        let started = manager
            .start(PairingStartRequest {
                device_id,
                device_name: "Mac".into(),
                code,
                pinned_tls_fingerprint: "fingerprint".into(),
            })
            .unwrap();
        assert!(!manager.authorize(device_id, "guess"));
        let issued = manager.approve(started.request_id, true).unwrap().unwrap();
        assert!(manager.authorize(device_id, &issued.credential));
        assert!(manager.revoke(device_id));
        assert!(!manager.authorize(device_id, &issued.credential));
    }
}
