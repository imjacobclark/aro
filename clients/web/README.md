# Aro Web

Aro's mobile-first web client: the macOS app's library, playback, and metadata editing,
rebuilt as an installable PWA and served from the machine that hosts the hub.

It is a renderer, not a second brain. Every playlist, radio station, smart shuffle, cover,
and listening statistic comes from `aro-server` — the same source the macOS app reads —
so the two clients cannot drift into disagreeing about your library.

## How it reaches the hub

The hub's sync API is HTTPS on port 4848 with a self-signed certificate and a bearer
token on every route. A browser can do neither: it has no way to pin a certificate it was
not given, and a token shipped to the browser is a token given away.

So this app is a backend-for-frontend. Its own server holds the hub's admin token and
pins the hub's certificate, and the browser only ever talks to this app:

```
browser ──▶ /api/hub/…      ──▶ https://127.0.0.1:4848/v1/…   (JSON, token attached here)
        ──▶ /api/stream/…   ──▶ /v1/blobs/{hash}/stream        (audio, byte ranges intact)
        ──▶ /api/artwork/…  ──▶ /v1/blobs/{hash}               (covers, cached forever)
```

`src/lib/hub/routes.ts` is an allowlist of exactly which hub paths the browser may reach
and with which verb. Adding a capability to the UI means adding a line there — nothing is
reachable by guessing a URL.

There is deliberately **no user authentication**. Anyone who can reach this port can use
the library, which is the same trust boundary the LAN dashboard already assumes. Do not
expose the port beyond your own network.

## Running it locally

```sh
cp .env.example .env.local
# Set ARO_ADMIN_TOKEN to the admin_token from your hub's aro.toml, and point
# ARO_HUB_URL at the hub. For a hub whose certificate you have not copied locally,
# set ARO_HUB_INSECURE=true rather than leaving verification half-configured.
npm install
npm run dev
```

From the repository root, `make web run`, `make web build`, and `make web test` do the
same things.

## Deploying to the hub

```sh
./scripts/deploy-web.sh --host mercury --user imjacobclark
```

That cross-builds a `linux/arm/v7` image on your Mac, ships it over SSH, and installs it
as a systemd-managed container next to `aro-server`. It installs `docker.io` if the host
does not have it, reads the admin token and TLS certificate off the hub itself, opens the
port to the LAN if `ufw` is active, and waits for `/api/health` before reporting success.
It never stops or reconfigures `aro-server`.

### Why it is served over HTTPS

The deploy also puts the app behind `tailscale serve`, which fronts it with a real
certificate for the machine's `ts.net` name. That is not decoration. A browser only grants
**secure contexts** — HTTPS, or `localhost` — service workers, Add to Home Screen, and parts
of the crypto API. Reached as plain `http://mercury:4851` the app is not a secure context,
so it cannot install, cannot work offline, and `crypto.randomUUID` does not exist.

This is easy to miss, because `http://127.0.0.1` *is* a secure context: the app can work
perfectly in local development and fail on the very same build once it is addressed by
hostname. Test against a non-loopback origin before believing it works.

Both routes stay open, and they are not equivalent:

| Address | Secure context | Installable | Works offline |
|---|---|---|---|
| `https://<node>.ts.net/` | yes | yes | yes |
| `http://mercury:4851` (LAN) | no | no | no |

`serve` publishes to your tailnet only. `funnel` would publish to the internet, and this
deliberately never uses it — the app has no authentication, by design.

Pass `--no-tailscale-serve` to leave Tailscale's configuration untouched.

The Next.js build runs on the *builder's* architecture rather than under emulation — a
build produces JavaScript, which does not care what CPU it was produced on — so this takes
minutes rather than hours.

## What it does not do

Uploading or importing music. Contributing files needs a paired device identity, which is
established by a PAKE handshake meant for a person holding two devices; a server-side
process cannot complete one. The web client reads, plays, and edits; the macOS app and the
hub's own watched folders are how music gets in.

## Layout

```text
src/app/          Routes. `api/` is the BFF; everything else is a screen.
src/components/   UI. `ui/` holds the shadcn-shaped primitives.
src/lib/hub/      The hub: wire types, the server-side client, the browser-side client.
src/lib/catalog/  The whole library in memory, cached in IndexedDB, grouped into albums.
src/lib/playback/ The player, the queue, and what gets reported back to the hub.
public/sw.js      The service worker. It never touches `/api/stream/`.
```
