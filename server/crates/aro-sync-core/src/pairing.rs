use aes_gcm::{
    Aes128Gcm, KeyInit,
    aead::{Aead, Payload},
};
use aro_sync_protocol::{
    DeviceCredential, DeviceSummary, EncryptedPairingResult, PairingConfirmResponse,
    PairingPake1Response, PairingResult, PairingStartRequest, PairingStartResponse, PairingState,
    PairingStatusResponse, PendingPairingRequest,
};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use chrono::{DateTime, Duration, Utc};
use matter_crypto::pase::{PasePbkdfParams, PaseVerifier};
use parking_lot::RwLock;
use rand::{Rng, RngCore, distr::Alphanumeric};
use sha2::{Digest, Sha256};
use std::{collections::HashMap, sync::Arc};
use subtle::ConstantTimeEq;
use thiserror::Error;
use uuid::Uuid;

const PBKDF_ITERATIONS: u32 = 10_000;
const MAX_PAIRING_STARTS: u8 = 10;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PairingError {
    #[error("pairing is unavailable")]
    Unavailable,
    #[error("invalid or expired pairing code")]
    InvalidCode,
    #[error("invalid pairing handshake")]
    InvalidHandshake,
    #[error("too many pairing attempts; open a new pairing window")]
    TooManyAttempts,
    #[error("pairing request not found")]
    RequestNotFound,
}

struct Pending {
    device_id: Uuid,
    device_name: String,
    device_type: String,
    expires_at: DateTime<Utc>,
    state: PairingState,
    authenticated: bool,
    verifier: Option<PaseVerifier>,
    result_key: Option<[u8; 16]>,
    credential: Option<DeviceCredential>,
}

struct Device {
    summary: DeviceSummary,
    credential_hash: [u8; 32],
}

struct State {
    code: Option<String>,
    code_expires_at: DateTime<Utc>,
    pairing_starts: u8,
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
                pairing_starts: 0,
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
        state.pairing_starts = 0;
        state.pending.clear();
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
        let now = Utc::now();
        let Some(code) = state.code.clone() else {
            return Err(PairingError::Unavailable);
        };
        if now >= state.code_expires_at {
            return Err(PairingError::InvalidCode);
        }
        if state.pairing_starts >= MAX_PAIRING_STARTS {
            return Err(PairingError::TooManyAttempts);
        }
        state.pairing_starts += 1;

        let pin = code.parse::<u32>().map_err(|_| PairingError::InvalidCode)?;
        let request_bytes = BASE64
            .decode(&request.pbkdf_request)
            .map_err(|_| PairingError::InvalidHandshake)?;
        let mut salt = vec![0u8; 16];
        rand::rng().fill_bytes(&mut salt);
        let mut verifier = PaseVerifier::new_from_pin(
            pin,
            PasePbkdfParams {
                iterations: PBKDF_ITERATIONS,
                salt,
            },
            1,
        )
        .map_err(|_| PairingError::InvalidHandshake)?;
        verifier
            .handle_pbkdf_request(&request_bytes)
            .map_err(|_| PairingError::InvalidHandshake)?;
        let response = verifier
            .next_message()
            .map_err(|_| PairingError::InvalidHandshake)?;

        let request_id = Uuid::new_v4();
        let expires_at = state.code_expires_at;
        state.pending.insert(
            request_id,
            Pending {
                device_id: request.device_id,
                device_name: request.device_name,
                device_type: request.device_type.unwrap_or_else(|| "Mac".into()),
                expires_at,
                state: PairingState::Pending,
                authenticated: false,
                verifier: Some(verifier),
                result_key: None,
                credential: None,
            },
        );
        Ok(PairingStartResponse {
            request_id,
            pbkdf_response: BASE64.encode(response),
        })
    }

    pub fn pake1(
        &self,
        request_id: Uuid,
        encoded_pake1: &str,
    ) -> Result<PairingPake1Response, PairingError> {
        let bytes = BASE64
            .decode(encoded_pake1)
            .map_err(|_| PairingError::InvalidHandshake)?;
        let mut state = self.state.write();
        let pending = state
            .pending
            .get_mut(&request_id)
            .ok_or(PairingError::RequestNotFound)?;
        if Utc::now() >= pending.expires_at {
            pending.state = PairingState::Expired;
            return Err(PairingError::InvalidCode);
        }
        let verifier = pending
            .verifier
            .as_mut()
            .ok_or(PairingError::InvalidHandshake)?;
        verifier
            .handle_pake1(&bytes)
            .map_err(|_| PairingError::InvalidHandshake)?;
        let pake2 = verifier
            .next_message()
            .map_err(|_| PairingError::InvalidHandshake)?;
        Ok(PairingPake1Response {
            pake2: BASE64.encode(pake2),
        })
    }

    pub fn confirm(
        &self,
        request_id: Uuid,
        encoded_pake3: &str,
    ) -> Result<PairingConfirmResponse, PairingError> {
        let bytes = BASE64
            .decode(encoded_pake3)
            .map_err(|_| PairingError::InvalidHandshake)?;
        let mut state = self.state.write();
        let pending = state
            .pending
            .get_mut(&request_id)
            .ok_or(PairingError::RequestNotFound)?;
        if Utc::now() >= pending.expires_at {
            pending.state = PairingState::Expired;
            return Err(PairingError::InvalidCode);
        }
        let mut verifier = pending
            .verifier
            .take()
            .ok_or(PairingError::InvalidHandshake)?;
        verifier
            .handle_pake3(&bytes)
            .map_err(|_| PairingError::InvalidCode)?;
        let keys = verifier
            .finish()
            .map_err(|_| PairingError::InvalidHandshake)?;
        pending.result_key = Some(keys.r2i_key);
        pending.authenticated = true;
        // A code is deliberately single-use once a client proves possession.
        state.code = None;
        Ok(PairingConfirmResponse {
            state: PairingState::Pending,
        })
    }

    pub fn approve(
        &self,
        request_id: Uuid,
        approve: bool,
        can_contribute: bool,
    ) -> Result<Option<DeviceCredential>, PairingError> {
        let mut state = self.state.write();
        let pending = state
            .pending
            .get_mut(&request_id)
            .ok_or(PairingError::RequestNotFound)?;
        if !pending.authenticated {
            return Err(PairingError::InvalidHandshake);
        }
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
        let device_type = pending.device_type.clone();
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
                    device_type,
                    paired_at: Utc::now(),
                    revoked_at: None,
                    last_seen_at: None,
                    last_synced_at: None,
                    offline_track_count: None,
                    can_contribute,
                },
                credential_hash,
            },
        );
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
        if pending.device_id != device_id || !pending.authenticated {
            return Err(PairingError::RequestNotFound);
        }
        if pending.state == PairingState::Pending && Utc::now() >= pending.expires_at {
            pending.state = PairingState::Expired;
        }
        let encrypted_result = match (&pending.credential, pending.result_key) {
            (Some(credential), Some(key)) if pending.state == PairingState::Approved => {
                let plaintext = serde_json::to_vec(&PairingResult {
                    credential: credential.clone(),
                    tls_fingerprint: self.fingerprint.clone(),
                })
                .map_err(|_| PairingError::InvalidHandshake)?;
                let mut nonce = [0u8; 12];
                rand::rng().fill_bytes(&mut nonce);
                let aad = pairing_aad(request_id, device_id);
                let cipher =
                    Aes128Gcm::new_from_slice(&key).map_err(|_| PairingError::InvalidHandshake)?;
                let ciphertext = cipher
                    .encrypt(
                        (&nonce).into(),
                        Payload {
                            msg: &plaintext,
                            aad: aad.as_bytes(),
                        },
                    )
                    .map_err(|_| PairingError::InvalidHandshake)?;
                Some(EncryptedPairingResult {
                    nonce: BASE64.encode(nonce),
                    ciphertext: BASE64.encode(ciphertext),
                })
            }
            _ => None,
        };
        Ok(PairingStatusResponse {
            state: pending.state.clone(),
            encrypted_result,
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

    pub fn pending_requests(&self) -> Vec<PendingPairingRequest> {
        let now = Utc::now();
        let mut state = self.state.write();
        for pending in state.pending.values_mut() {
            if pending.state == PairingState::Pending && now >= pending.expires_at {
                pending.state = PairingState::Expired;
            }
        }
        let mut requests: Vec<_> = state
            .pending
            .iter()
            .filter(|(_, pending)| pending.authenticated && pending.state == PairingState::Pending)
            .map(|(request_id, pending)| PendingPairingRequest {
                request_id: *request_id,
                device_id: pending.device_id,
                device_name: pending.device_name.clone(),
                device_type: pending.device_type.clone(),
                expires_at: pending.expires_at,
            })
            .collect();
        requests.sort_by_key(|request| request.expires_at);
        requests
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

fn pairing_aad(request_id: Uuid, device_id: Uuid) -> String {
    format!("aro-pairing-v2:{request_id}:{device_id}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes_gcm::aead::Aead;
    use matter_crypto::pase::PaseProver;

    fn complete_handshake(
        manager: &PairingManager,
        code: &str,
        device_id: Uuid,
        device_name: &str,
    ) -> (Uuid, [u8; 16]) {
        let mut prover = PaseProver::new_with_negotiation(code.parse().unwrap(), 1).unwrap();
        let pbkdf_request = prover.start().unwrap();
        let started = manager
            .start(PairingStartRequest {
                device_id,
                device_name: device_name.into(),
                device_type: Some("Mac".into()),
                pbkdf_request: BASE64.encode(pbkdf_request),
            })
            .unwrap();
        prover
            .handle_pbkdf_response(&BASE64.decode(started.pbkdf_response).unwrap())
            .unwrap();
        let pake1 = prover.next_message().unwrap();
        let pake2 = manager
            .pake1(started.request_id, &BASE64.encode(pake1))
            .unwrap();
        prover
            .handle_pake2(&BASE64.decode(pake2.pake2).unwrap())
            .unwrap();
        let pake3 = prover.next_message().unwrap();
        manager
            .confirm(started.request_id, &BASE64.encode(pake3))
            .unwrap();
        let keys = prover.finish().unwrap();
        (started.request_id, keys.r2i_key)
    }

    #[test]
    fn code_authenticated_approved_devices_are_authorized_and_revocation_is_immediate() {
        let manager = PairingManager::new("fingerprint".into());
        let code = manager.open(Duration::minutes(1));
        let device_id = Uuid::new_v4();
        let (request_id, result_key) = complete_handshake(&manager, &code, device_id, "Mac");
        assert!(!manager.authorize(device_id, "guess"));
        let issued = manager.approve(request_id, true, false).unwrap().unwrap();
        assert!(manager.authorize(device_id, &issued.credential));

        let status = manager.status(request_id, device_id).unwrap();
        let encrypted = status.encrypted_result.unwrap();
        let nonce: [u8; 12] = BASE64.decode(encrypted.nonce).unwrap().try_into().unwrap();
        let ciphertext = BASE64.decode(encrypted.ciphertext).unwrap();
        let plaintext = Aes128Gcm::new_from_slice(&result_key)
            .unwrap()
            .decrypt(
                (&nonce).into(),
                Payload {
                    msg: &ciphertext,
                    aad: pairing_aad(request_id, device_id).as_bytes(),
                },
            )
            .unwrap();
        let result: PairingResult = serde_json::from_slice(&plaintext).unwrap();
        assert_eq!(result.credential, issued);
        assert_eq!(result.tls_fingerprint, "fingerprint");

        assert!(manager.revoke(device_id));
        assert!(!manager.authorize(device_id, &issued.credential));
    }

    #[test]
    fn pending_requests_are_visible_only_after_code_proof() {
        let manager = PairingManager::new("fingerprint".into());
        let code = manager.open(Duration::minutes(1));
        let device_id = Uuid::new_v4();
        let (request_id, _) = complete_handshake(&manager, &code, device_id, "Living Room Mac");

        let requests = manager.pending_requests();
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0].request_id, request_id);
        assert_eq!(requests[0].device_id, device_id);
        assert_eq!(requests[0].device_name, "Living Room Mac");

        manager.approve(request_id, true, false).unwrap();
        assert!(manager.pending_requests().is_empty());
    }

    #[test]
    fn wrong_code_never_reaches_hub_approval() {
        let manager = PairingManager::new("fingerprint".into());
        let _code = manager.open(Duration::minutes(1));
        let device_id = Uuid::new_v4();
        let mut prover = PaseProver::new_with_negotiation(999_999, 1).unwrap();
        let started = manager
            .start(PairingStartRequest {
                device_id,
                device_name: "Attacker".into(),
                device_type: Some("Mac".into()),
                pbkdf_request: BASE64.encode(prover.start().unwrap()),
            })
            .unwrap();
        prover
            .handle_pbkdf_response(&BASE64.decode(started.pbkdf_response).unwrap())
            .unwrap();
        let pake2 = manager
            .pake1(
                started.request_id,
                &BASE64.encode(prover.next_message().unwrap()),
            )
            .unwrap();
        prover
            .handle_pake2(&BASE64.decode(pake2.pake2).unwrap())
            .unwrap_err();
        assert!(manager.pending_requests().is_empty());
    }
}
