//! Wire types for the versioned Aro LAN synchronization protocol.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use uuid::Uuid;

pub const MIN_PROTOCOL_VERSION: u16 = 2;
pub const PROTOCOL_VERSION: u16 = 5;
pub const SERVICE_TYPE: &str = "_aro-sync._tcp.local.";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct HubInfo {
    pub hub_id: Uuid,
    pub display_name: String,
    pub protocol_min: u16,
    pub protocol_max: u16,
    pub pairing_available: bool,
    /// Whether this hub has an AcoustID key configured, so a client can tell
    /// "identification is off because nobody's turned it on here" apart from
    /// "identification is off because nothing's queued right now" -- a plain
    /// capability flag, never the key itself, so it's safe on this
    /// unauthenticated discovery endpoint.
    pub identification_available: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct NegotiateRequest {
    pub protocol_min: u16,
    pub protocol_max: u16,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct NegotiateResponse {
    pub selected_protocol: u16,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingStartRequest {
    pub device_id: Uuid,
    pub device_name: String,
    #[serde(default)]
    pub device_type: Option<String>,
    /// Base64-encoded Matter PASE PBKDFParamRequest.
    pub pbkdf_request: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingStartResponse {
    pub request_id: Uuid,
    /// Base64-encoded Matter PASE PBKDFParamResponse.
    pub pbkdf_response: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingPake1Request {
    /// Base64-encoded Matter PASE Pake1.
    pub pake1: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingPake1Response {
    /// Base64-encoded Matter PASE Pake2.
    pub pake2: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingConfirmRequest {
    /// Base64-encoded Matter PASE Pake3.
    pub pake3: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingConfirmResponse {
    pub state: PairingState,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PendingPairingRequest {
    pub request_id: Uuid,
    pub device_id: Uuid,
    pub device_name: String,
    #[serde(default = "default_device_type")]
    pub device_type: String,
    pub expires_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingStatusResponse {
    pub state: PairingState,
    pub encrypted_result: Option<EncryptedPairingResult>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct EncryptedPairingResult {
    /// Base64-encoded 96-bit AES-GCM nonce.
    pub nonce: String,
    /// Base64-encoded ciphertext and authentication tag.
    pub ciphertext: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingResult {
    pub credential: DeviceCredential,
    pub tls_fingerprint: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PairingState {
    Pending,
    Approved,
    Rejected,
    Expired,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PairingApprovalRequest {
    pub request_id: Uuid,
    pub approve: bool,
    #[serde(default)]
    pub can_contribute: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceCredential {
    pub device_id: Uuid,
    pub credential: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceSummary {
    pub device_id: Uuid,
    pub name: String,
    #[serde(default = "default_device_type")]
    pub device_type: String,
    pub paired_at: DateTime<Utc>,
    pub revoked_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub last_seen_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub last_synced_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub offline_track_count: Option<u64>,
    #[serde(default)]
    pub can_contribute: bool,
}

fn default_device_type() -> String {
    "Device".into()
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct RevokeRequest {
    pub device_id: Uuid,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ManifestEntry {
    pub local_track_id: String,
    pub hub_track_id: Option<Uuid>,
    pub content_hash: Option<String>,
    pub fields: BTreeMap<String, VersionedValue>,
    pub tombstoned: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct JoinPreviewRequest {
    pub device_id: Uuid,
    pub manifest: Vec<ManifestEntry>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct JoinPreview {
    pub preview_id: Uuid,
    pub deduplicated_tracks: usize,
    pub local_only_tracks: usize,
    pub hub_only_tracks: usize,
    pub conflicts: Vec<FieldConflict>,
    pub required_bytes: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct JoinCommitRequest {
    pub preview_id: Uuid,
    pub resolutions: BTreeMap<String, ConflictChoice>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ConflictChoice {
    Local,
    Hub,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct FieldConflict {
    pub track_id: Uuid,
    pub field: String,
    pub local: VersionedValue,
    pub hub: VersionedValue,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct HybridTimestamp {
    pub physical_millis: i64,
    pub logical: u32,
    pub device_id: Uuid,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct VersionedValue {
    pub value: Value,
    pub timestamp: HybridTimestamp,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Operation {
    pub operation_id: Uuid,
    pub device_id: Uuid,
    pub entity_type: String,
    pub entity_id: String,
    pub kind: String,
    pub payload: Value,
    pub field_versions: BTreeMap<String, HybridTimestamp>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct SequencedOperation {
    pub sequence: u64,
    #[serde(flatten)]
    pub operation: Operation,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ExchangeRequest {
    pub after_sequence: u64,
    pub limit: u32,
    pub operations: Vec<Operation>,
    #[serde(default)]
    pub device_report: Option<DeviceSyncReport>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DeviceSyncReport {
    pub offline_track_count: u64,
    #[serde(default)]
    pub sources: Vec<SourceHealthReport>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SourceHealthReport {
    pub source_id: Uuid,
    pub name: String,
    pub mode: String,
    pub available: bool,
    pub warning: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ExchangeResponse {
    pub accepted: Vec<SequencedOperation>,
    pub changes: Vec<SequencedOperation>,
    pub next_cursor: u64,
    pub has_more: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct SnapshotPage {
    pub tracks: Vec<ManifestEntry>,
    pub next_cursor: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct BlobStatus {
    pub hash: String,
    pub exists: bool,
    pub committed_size: u64,
    pub uploaded_size: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct BlobCommitRequest {
    pub hash: String,
    pub size: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExportManifest {
    pub schema_version: u16,
    pub library_name: String,
    pub generated_at: DateTime<Utc>,
    pub tracks: Vec<ExportTrack>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExportTrack {
    pub track_id: Uuid,
    pub content_hash: String,
    pub byte_count: u64,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub track_number: Option<u32>,
    pub disc_number: Option<u32>,
    pub original_filename: String,
    pub original_extension: String,
    pub removed_at: Option<DateTime<Utc>>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct DevicePermissionRequest {
    pub device_id: Uuid,
    pub can_contribute: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyncJob {
    pub job_id: Uuid,
    pub kind: String,
    pub state: JobState,
    pub completed_units: u64,
    pub total_units: u64,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    Pending,
    Running,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct PlaybackActivitySnapshot {
    pub session_id: Uuid,
    pub revision: u64,
    pub content_hash: String,
    pub state: PlaybackActivityState,
    pub position_seconds: f64,
    pub duration_seconds: Option<f64>,
    pub buffered_fraction: Option<f64>,
    pub observed_at: DateTime<Utc>,
    pub started_at: DateTime<Utc>,
    #[serde(default)]
    pub completed: bool,
    #[serde(default)]
    pub output: Option<PlaybackOutputSnapshot>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackActivityState {
    Playing,
    Buffering,
    Stopped,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct PlaybackOutputSnapshot {
    pub route_name: Option<String>,
    pub playback_mode: Option<String>,
    pub sample_rate: Option<f64>,
    pub bit_depth: Option<u32>,
    pub exclusive: Option<bool>,
    pub wireless: Option<bool>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ErrorResponse {
    pub code: String,
    pub message: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixture_round_trip_preserves_operation() {
        let operation = Operation {
            operation_id: Uuid::nil(),
            device_id: Uuid::nil(),
            entity_type: "track_state".into(),
            entity_id: "track-1".into(),
            kind: "update".into(),
            payload: serde_json::json!({"favourite": true}),
            field_versions: BTreeMap::new(),
        };
        let encoded = serde_json::to_string(&operation).unwrap();
        assert_eq!(
            serde_json::from_str::<Operation>(&encoded).unwrap(),
            operation
        );
    }

    #[test]
    fn committed_v1_fixture_matches_wire_contract() {
        let fixture = include_str!("../../../fixtures/operation-v1.json");
        let operation: Operation = serde_json::from_str(fixture).unwrap();
        assert_eq!(operation.entity_type, "track_state");
        assert_eq!(
            operation.field_versions["favourite"].physical_millis,
            1_700_000_000_000
        );
    }
}
