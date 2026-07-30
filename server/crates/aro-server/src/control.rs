use crate::http::AppState;
use anyhow::Result;
use chrono::Duration;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    task::JoinHandle,
};
use uuid::Uuid;

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum ControlCommand {
    OpenPairing,
    PendingPairingRequests,
    Approve {
        request_id: Uuid,
        approve: bool,
        #[serde(default)]
        can_contribute: bool,
    },
    Devices,
    SetContribution {
        device_id: Uuid,
        allowed: bool,
    },
    RemoveTrack {
        content_hash: String,
    },
    Revoke {
        device_id: Uuid,
    },
    Import {
        path: PathBuf,
        #[serde(rename = "mode")]
        _mode: String,
    },
    Folders,
    ScanFolder {
        source_id: Option<Uuid>,
    },
    RemoveFolder {
        source_id: Uuid,
    },
    /// Enqueues one or more files for (re-)identification. Used for both "Sync Track
    /// Data" (one file) and "Sync Album Data" (every file in the album, resolved
    /// client-side — the server has no album grouping of its own). Keyed by content
    /// hash and absolute path rather than a track id: this server's `hub_track_id`s
    /// and the macOS app's own local library track ids are generated independently
    /// and never coincide, so content hash is the only identifier they share.
    IdentifyTracks {
        tracks: Vec<IdentifyTrackRequest>,
    },
    IdentificationStatus,
    /// Identification results recorded after `after` (exclusive), oldest first — the
    /// pull side the macOS app polls to merge results into its own local library
    /// catalog by content hash.
    IdentificationResults {
        after: i64,
        #[serde(default = "default_identification_results_limit")]
        limit: u32,
    },
    SetSetting {
        key: String,
        value: Value,
    },
    Setting {
        key: String,
    },
    /// Reads a blob's bytes directly off this host's own store, base64-encoded
    /// into the JSON response. Exists for the macOS app running *this same*
    /// hub locally: it already reaches this socket for identification
    /// results, so cached artwork (see `IdentificationResults.artwork_url`,
    /// which points at `/v1/blobs/{hash}` since `aro-track-id` started
    /// caching Cover Art Archive images) is one local round-trip away without
    /// needing the HTTP layer's device/admin auth or a real network
    /// connection at all — appropriate here since this socket is already
    /// filesystem-permission-gated (0600) to the local user, unlike the HTTP
    /// blob endpoint which is reachable from other paired devices.
    Blob {
        hash: String,
    },
    /// Auto-generated playlists derived from this hub's canonical analytics (listening
    /// events, favourites, MusicBrainz mood tags) — see `crate::playlists`. Keyed by
    /// content hash; the macOS app maps hashes onto its local catalog and renders. The
    /// hub generates, clients never do.
    Playlists,
    Status,
}

#[derive(Deserialize)]
struct IdentifyTrackRequest {
    content_hash: String,
    path: PathBuf,
}

fn default_identification_results_limit() -> u32 {
    200
}

#[derive(Serialize)]
struct ControlResponse {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

const CONTROL_PROTOCOL_VERSION: u16 = 7;

pub async fn start(path: &Path, state: Arc<AppState>) -> Result<JoinHandle<()>> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    if path.exists() {
        tokio::fs::remove_file(path).await?;
    }
    let listener = UnixListener::bind(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).await?;
    }
    Ok(tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                break;
            };
            let state = state.clone();
            tokio::spawn(async move {
                if let Err(error) = respond(stream, state).await {
                    tracing::warn!(%error, "control socket request failed");
                }
            });
        }
    }))
}

async fn respond(mut stream: UnixStream, state: Arc<AppState>) -> Result<()> {
    let response = match handle(&mut stream, state).await {
        Ok(result) => ControlResponse {
            ok: true,
            result: Some(result),
            error: None,
        },
        Err(error) => {
            tracing::warn!(%error, "control socket request rejected");
            ControlResponse {
                ok: false,
                result: None,
                error: Some(error.to_string()),
            }
        }
    };
    stream.write_all(&serde_json::to_vec(&response)?).await?;
    stream.shutdown().await?;
    Ok(())
}

async fn handle(stream: &mut UnixStream, state: Arc<AppState>) -> Result<Value> {
    let mut request = Vec::new();
    {
        let mut reader = BufReader::new(stream);
        reader.read_until(b'\n', &mut request).await?;
    }
    if request.len() > 64 * 1_024 {
        anyhow::bail!("control request too large");
    }
    let command: ControlCommand = serde_json::from_slice(&request)?;
    let result = match command {
        ControlCommand::OpenPairing => {
            let code = state.pairing.open(Duration::minutes(5));
            json!({
                "code": code,
                "expires_in_seconds": 300
            })
        }
        ControlCommand::PendingPairingRequests => {
            serde_json::to_value(state.pairing.pending_requests())?
        }
        ControlCommand::Approve {
            request_id,
            approve,
            can_contribute,
        } => {
            let credential = state.pairing.approve(request_id, approve, can_contribute)?;
            if let Some(credential) = &credential {
                let summary = state
                    .pairing
                    .devices()
                    .into_iter()
                    .find(|device| device.device_id == credential.device_id)
                    .ok_or_else(|| anyhow::anyhow!("approved device missing"))?;
                state.store.save_device(&summary, &credential.credential)?;
            }
            serde_json::to_value(credential)?
        }
        ControlCommand::Devices => serde_json::to_value(state.store.devices()?)?,
        ControlCommand::SetContribution { device_id, allowed } => {
            let updated = state.store.set_device_contribution(device_id, allowed)?;
            json!({"updated": updated})
        }
        ControlCommand::RemoveTrack { content_hash } => {
            let removed = state.store.tombstone_by_hash(&content_hash, state.hub_id)?;
            json!({"removed": removed})
        }
        ControlCommand::Revoke { device_id } => {
            let revoked = state.store.revoke_device(device_id)?;
            state.pairing.revoke(device_id);
            json!({"revoked": revoked})
        }
        ControlCommand::Import { path, _mode: _ } => {
            let sources = state.sources.clone();
            let folder = tokio::task::spawn_blocking(move || sources.add(&path)).await??;
            json!({
                "imported_songs": folder.song_count,
                "imported_tracks": folder.song_count,
                "source_id": folder.source_id
            })
        }
        ControlCommand::Folders => serde_json::to_value(state.sources.list()?)?,
        ControlCommand::ScanFolder { source_id } => {
            let sources = state.sources.clone();
            let changed = tokio::task::spawn_blocking(move || match source_id {
                Some(id) => sources.scan(id),
                None => {
                    sources.scan_all()?;
                    Ok(0)
                }
            })
            .await??;
            json!({"changed_songs": changed})
        }
        ControlCommand::RemoveFolder { source_id } => {
            json!({"removed": state.sources.remove(source_id)?})
        }
        ControlCommand::IdentifyTracks { tracks } => {
            let identification = state.sources.identification();
            for track in &tracks {
                identification.enqueue(track.content_hash.clone(), track.path.clone());
            }
            json!({"queued": tracks.len()})
        }
        ControlCommand::IdentificationStatus => {
            serde_json::to_value(state.sources.identification().status().await)?
        }
        ControlCommand::IdentificationResults { after, limit } => {
            serde_json::to_value(state.store.identification_results_since(after, limit)?)?
        }
        ControlCommand::SetSetting { key, value } => {
            state.store.set_setting(&key, &value)?;
            json!({"ok": true})
        }
        ControlCommand::Setting { key } => json!({"value": state.store.setting(&key)?}),
        ControlCommand::Blob { hash } => {
            let path = state
                .store
                .blob_path_for_download(&hash)?
                .ok_or_else(|| anyhow::anyhow!("blob not found"))?;
            let bytes = tokio::fs::read(&path).await?;
            json!({
                "data_base64": base64::Engine::encode(
                    &base64::engine::general_purpose::STANDARD,
                    bytes
                )
            })
        }
        ControlCommand::Playlists => {
            let store = state.store.clone();
            let seeds = tokio::task::spawn_blocking(move || store.playlist_seeds()).await??;
            serde_json::to_value(crate::playlists::generate(&seeds, chrono::Utc::now()))?
        }
        ControlCommand::Status => json!({
            "control_protocol_version": CONTROL_PROTOCOL_VERSION,
            "hub_id": state.hub_id,
            "display_name": state.display_name,
            "sequence": state.store.latest_sequence()?,
            "pairing_available": state.pairing.is_open()
            ,"storage_mode": state.sources.mode().as_str()
        }),
    };
    Ok(result)
}
