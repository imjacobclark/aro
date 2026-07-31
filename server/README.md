# Aro LAN Library Server

The Aro server is authoritative and owns its own SQLite database and content-addressed
media directory. It never opens a Aro client database and never transfers
SQLite, WAL, watched-folder bookmarks, or device playback settings.

Initialize and run:

```sh
cargo run -p aro-server -- --config ./aro.toml init \
  --mode managed --data-dir ./library-data
cargo run -p aro-server -- --config ./aro.toml serve
```

Configuration is TOML with `ARO_CONFIG`, `ARO_BIND`,
`ARO_DATA_DIR`, and `ARO_ADMIN_TOKEN` overrides. The server rejects
public bind addresses. Bonjour advertises `_aro-sync._tcp.local.` with only
the Aro ID, display name, protocol version, and pairing availability. Manual
`https://hostname:4848` entry is supported by clients when multicast is absent.

### Optional LAN intelligence dashboard

The server can expose a read-only, unauthenticated dashboard on a separate
plain-HTTP listener. It is disabled by default and configuration changes take
effect after restarting the server:

```toml
[dashboard]
enabled = true
bind = "0.0.0.0:4849"
```

Open `http://hostname:4849/` for live listeners and transfers, consolidated
listening/library statistics, metadata coverage, source and host health.
Machine-readable data is available under `/api/v1/`; Prometheus can scrape
`/metrics`.

The dashboard intentionally reveals library metadata, device identity, peer
addresses, and local paths to anyone who can reach its port. Its bind address
must be private or loopback. Do not forward it to the public internet. Device
and local playback reporting remains authenticated on the TLS sync listener.

### Optional DLNA media server

The server can also expose the library as a standard DLNA/UPnP media server
(MediaServer:1 with ContentDirectory:1), so TVs, AV receivers, consoles, and
UPnP apps can browse and play it without an Aro client. It is disabled by
default and takes effect after restarting the server:

```toml
[dlna]
enabled = true
bind = "0.0.0.0:4850"
# friendly_name = "Living Room Aro"   # defaults to display_name
```

`aro-server config set dlna.enabled true` toggles it without hand-editing
TOML; `ARO_DLNA_BIND` overrides the bind address.

Renderers browse Artists, Albums, All Tracks, and the server-generated
Playlists. Files are served in their original format with real MIME types —
there is no transcoding, so a renderer must support the codec (modern devices
handle FLAC/MP3/AAC). Discovery uses SSDP on UDP port 1900; the HTTP listener
answers on the configured bind (default 4850).

DLNA has no authentication: anyone who can reach the port can browse and fetch
every track. The bind address must be private or loopback, requests from
non-private peers are refused, and SSDP ignores searches from outside private
networks. Do not forward either port to the public internet.

The storage mode belongs to the entire Aro and is fixed at initialization.
Managed storage always copies files and publishes them only after SHA-256
verification; it never creates hard links. Referenced storage records verified
canonical paths and serves them in place.

Manage continuously watched import folders while the server is running:

```sh
aro-server --config /etc/aro/aro.toml folders add /srv/music
aro-server --config /etc/aro/aro.toml folders list
aro-server --config /etc/aro/aro.toml folders scan --all
aro-server --config /etc/aro/aro.toml folders remove SOURCE_ID
```

The native watcher reconciles changes after a short stability delay and a
five-minute safety scan catches events missed by network filesystems. Replacing
a file at the same path updates the same logical song. Missing files and
detached folders keep their songs; Managed copies remain playable.

Pairing uses a five-minute, single-use six-digit code with a SPAKE2+
password-authenticated exchange. The TLS certificate pin and device credential
are encrypted under the negotiated key, so clients do not enter or compare a
fingerprint. Device credentials are bearer secrets and should be stored in the
platform credential vault. Run `aro-server pair`, submit the displayed code
on the client, then list and approve the request:

```sh
aro-server --config /etc/aro/aro.toml pairing requests
aro-server --config /etc/aro/aro.toml approve REQUEST_ID
```

Move a stopped standalone Aro—including its database, media, TLS identity,
credentials, and upload state—to a new disk with:

```sh
sudo systemctl stop aro-server
aro-server --config /etc/aro/aro.toml migrate --to /mnt/music/Aro
sudo systemctl start aro-server
```

Migration verifies the current and copied stores, switches the configuration
only after success, and retains the previous directory as a timestamped backup.

`Dockerfile` is architecture-independent and can be built for `linux/amd64` and
`linux/arm64`. Packaging includes launchd and systemd definitions. Windows
deployments can wrap `aro-server serve` with the Windows Service Control
Manager; native service registration is planned before a signed installer.
