# Sonora LAN Library Server

The Sonora server is authoritative and owns its own SQLite database and content-addressed
media directory. It never opens a Sonora client database and never transfers
SQLite, WAL, watched-folder bookmarks, or device playback settings.

Initialize and run:

```sh
cargo run -p sonora-server -- --config ./sonora.toml init \
  --mode managed --data-dir ./library-data
cargo run -p sonora-server -- --config ./sonora.toml serve
```

Configuration is TOML with `SONORA_CONFIG`, `SONORA_BIND`,
`SONORA_DATA_DIR`, and `SONORA_ADMIN_TOKEN` overrides. The server rejects
public bind addresses. Bonjour advertises `_sonora-sync._tcp.local.` with only
the Sonora ID, display name, protocol version, and pairing availability. Manual
`https://hostname:4848` entry is supported by clients when multicast is absent.

The storage mode belongs to the entire Sonora and is fixed at initialization.
Managed storage always copies files and publishes them only after SHA-256
verification; it never creates hard links. Referenced storage records verified
canonical paths and serves them in place.

Manage continuously watched import folders while the server is running:

```sh
sonora-server --config /etc/sonora/sonora.toml folders add /srv/music
sonora-server --config /etc/sonora/sonora.toml folders list
sonora-server --config /etc/sonora/sonora.toml folders scan --all
sonora-server --config /etc/sonora/sonora.toml folders remove SOURCE_ID
```

The native watcher reconciles changes after a short stability delay and a
five-minute safety scan catches events missed by network filesystems. Replacing
a file at the same path updates the same logical song. Missing files and
detached folders keep their songs; Managed copies remain playable.

Pairing uses a five-minute, single-use six-digit code with a SPAKE2+
password-authenticated exchange. The TLS certificate pin and device credential
are encrypted under the negotiated key, so clients do not enter or compare a
fingerprint. Device credentials are bearer secrets and should be stored in the
platform credential vault. Run `sonora-server pair`, submit the displayed code
on the client, then list and approve the request:

```sh
sonora-server --config /etc/sonora/sonora.toml pairing requests
sonora-server --config /etc/sonora/sonora.toml approve REQUEST_ID
```

Move a stopped standalone Sonora—including its database, media, TLS identity,
credentials, and upload state—to a new disk with:

```sh
sudo systemctl stop sonora-server
sonora-server --config /etc/sonora/sonora.toml migrate --to /mnt/music/Sonora
sudo systemctl start sonora-server
```

Migration verifies the current and copied stores, switches the configuration
only after success, and retains the previous directory as a timestamped backup.

`Dockerfile` is architecture-independent and can be built for `linux/amd64` and
`linux/arm64`. Packaging includes launchd and systemd definitions. Windows
deployments can wrap `sonora-server serve` with the Windows Service Control
Manager; native service registration is planned before a signed installer.
