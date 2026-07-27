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
    Status,
}

#[derive(Serialize)]
struct ControlResponse {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

const CONTROL_PROTOCOL_VERSION: u16 = 5;

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
