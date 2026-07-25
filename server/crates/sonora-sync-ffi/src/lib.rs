//! Stable facade boundary reserved for a future UniFFI foreground iOS host.
//! The macOS client deliberately does not link this crate.

use sonora_sync_protocol::PROTOCOL_VERSION;

pub fn protocol_version() -> u16 {
    PROTOCOL_VERSION
}
