# Sonora LAN Library Hub

The hub is authoritative and owns its own SQLite database and content-addressed
media directory. It never opens a Sonora client database and never transfers
SQLite, WAL, watched-folder bookmarks, or device playback settings.

Initialize and run:

```sh
cargo run -p sonora-server -- init --data-dir ./hub-data
cargo run -p sonora-server -- serve
```

Configuration is TOML with `SONORA_CONFIG`, `SONORA_BIND`,
`SONORA_DATA_DIR`, and `SONORA_ADMIN_TOKEN` overrides. The server rejects
public bind addresses. Bonjour advertises `_sonora-sync._tcp.local.` with only
the hub ID, display name, protocol version, and pairing availability. Manual
`https://hostname:4848` entry is supported by clients when multicast is absent.

`sonora-server import /music` defaults to managed storage: it hard-links when
the source and server-data directory share a filesystem, copies otherwise, and
publishes only after SHA-256 verification. `--mode referenced` records verified
canonical source paths and serves them in place; changed or missing files are
marked unavailable rather than silently serving different bytes.

Pairing uses a five-minute, single-use six-digit code with a SPAKE2+
password-authenticated exchange. The TLS certificate pin and device credential
are encrypted under the negotiated key, so clients do not enter or compare a
fingerprint. Device credentials are bearer secrets and should be stored in the
platform credential vault. Run `sonora-server pair`, submit the displayed code
on the client, then run `sonora-server approve <request-id>` on the hub.

`Dockerfile` is architecture-independent and can be built for `linux/amd64` and
`linux/arm64`. Packaging includes launchd and systemd definitions. Windows
deployments can wrap `sonora-server serve` with the Windows Service Control
Manager; native service registration is planned before a signed installer.
