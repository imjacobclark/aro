# Client parity audit

Where `clients/macos` and `clients/web` diverge, in both directions, and what closing each
gap would actually take. Written 2026-08-07, against the hub API as it stands.

> **Status: every portable gap below has since been closed.** Radio, favourites, Play Next
> and Add to Queue reached the macOS track row; More Like This, playlist detail, folder
> browsing and the Metadata page reached the web client; and Library Health moved to the hub
> so both clients render one analysis over the complete set of files. The audit is kept as
> the record of what was found and why each item was worth doing. What remains genuinely
> open is listed under "Deliberate divergences" — offline downloads being the substantial
> one. The two Stats data sources have since been collapsed into one, on the hub.

Both clients read the same hub, so most gaps are *surfacing* gaps rather than capability
gaps — the data is usually already there. The exceptions are called out, because they are
what separates a morning's work from a project.

**Effort** below means: `small` — one surface, no new plumbing. `medium` — new state or a
new screen. `large` — needs server work or a new subsystem.

---

## Web → macOS

### 1. Radio from anywhere · small · no server work

The best example of the web app being ahead. Both clients call the same
`GET /v1/radio/{hash}`, but they expose it very differently:

| | macOS | web |
|---|---|---|
| Home hero carousel | ✅ | ✅ (per-card) |
| Playlist detail | ✅ | — (no detail view, see below) |
| Any track in the library | ❌ | ✅ (row action sheet) |
| Now playing | ❌ | ✅ (footer action) |
| Artist page | ❌ | ✅ |

On macOS radio is a Home feature; on web it is a property of *any track*, which is what
makes it feel good — you hear something, you pull the thread immediately.

**To port:** `SongTableView` already holds both `playback` and an optional `loadRadio`
(it passes them to `MoreLikeThisSection`), so the data source is in scope. `AppKitSongTable`
takes its row actions as closures — `onPlay`, `onSyncTrackData`, `onEditMetadata`,
`onRequestRemoval` — so this is one more closure, one more `NSMenuItem`, and a button in
`PlayerBar`. No new state, no new endpoint.

### 2. Play Next / Add to Queue · medium · no server work

Web has both in the track sheet. macOS `PlaybackController` has **no queue-mutation API at
all** — `play(song:queue:)` replaces the queue outright, and there is no way to append.

**To port:** add `playNext(_:)` and `addToQueue(_:)` to `PlaybackController`. The care is in
the invariants, not the insertion: `queue` and `canonicalQueue` are kept in step,
`currentIndex` has to survive an insert before it, and `reconcileAvailableSongs` must still
map cleanly afterwards. Then two context-menu items. Worth doing carefully — the queue is
the one piece of playback state a listener notices immediately when it is wrong.

### 3. Favourites as a first-class action · small–medium · no server work

macOS can only favourite the **currently playing** track, from `PlayerBar`. Web offers it
on every row, in the now-playing sheet, and as a "favourites only" filter on Songs.

This matters beyond convenience: favourites feed the hub's `recently-loved` and Favorites
Mix playlists, so a client that makes hearting awkward quietly starves Home.

**To port:** `setFavourite` already exists and is already threaded to `PlayerBar` — a
context-menu item is small. The filter is medium: either a `Destination.favourites` case
plus a sidebar row, or a filter toggle on `SongTableView`.

### 4. Cross-type search · medium · no server work

macOS filters the current view via `LibrarySearchField`. Web has a dedicated screen that
searches the whole catalogue at once and groups results into artists / albums / songs.

**To port:** a new destination reusing the existing grouping helpers. Genuinely nicer on
web today; on macOS the in-view filter is arguably right for a table, so this is a
judgement call rather than a defect.

---

## macOS → web

### 1. Metadata page · medium · **no server work** — best value

macOS has a whole Metadata destination: identification queue status, per-track comparison of
what Aro holds against what is in the file on disk, "Write to Files" per track or in bulk,
and Sync Album / Sync All Music Metadata. Web has only the per-track editor sheet.

**To port:** every endpoint it needs is *already* in the web BFF allowlist —
`metadata/deltas`, `identification/status`, `identify`, `identify/sweep`,
`metadata/write-back`, `metadata/write-back/enabled`, `jobs/{}`. This is pure UI work
against an API that is already reachable and already permitted. Highest value per hour of
anything in this document.

### 2. "More Like This" shelf · small · no server work

macOS appends a similar-tracks shelf below the song table, and on album and artist pages —
neighbours measured from the audio itself (tempo/energy/brightness/MFCC/chroma). Web has
nothing equivalent.

**To port:** it is powered by `GET /v1/radio/{hash}`, which the web client already wraps as
`api.radio` and already uses for its radio feature. Reuses the existing track-row component.
Given how well radio lands on web, this is the obvious companion.

### 3. Playlist detail view · small · no server work

Tapping a generated playlist on web plays it immediately; there is no way to see what is in
it first. macOS has `PlaylistDetailView` with the full track list, per-track actions, and a
radio entry point.

**To port:** one route reusing the existing track list. Small, and it removes the only place
where the web app is meaningfully *blinder* than the Mac app.

### 4. Per-folder browsing · small–medium · no server work

macOS's sidebar has a row per watched folder (`Destination.folder(UUID)`), so you can browse
one source at a time. Web *manages* folders in Settings — add, remove, rescan, unreachable
warnings — but cannot browse by them.

**To port:** the data is already there. `library/sources` is allowlisted and every
`CatalogTrack` carries `source_id` / `source_name`, so this is a filtered library view, not
a fetch.

### 5. Offline downloads · medium–large · no server work

macOS keeps media locally at a chosen **download quality**, separate from playback quality,
with job progress and a per-quality storage breakdown. The web service worker deliberately
*bypasses* `/api/stream/*` — that bypass is what keeps range requests working.

**To port:** the Cache API can hold audio, but this needs a download UI, quota handling,
eviction, and a careful exception to the service worker's stream bypass. iOS storage limits
make it materially harder than it looks. Real feature, not a port.

### 6. Library Health · large · **needs a new endpoint**

A whole macOS destination: exact duplicates, alternate encodings of the same recording,
moved files, missing files, and fragmented folders — with recommendations and reclaimable
space.

**Blocked on the hub.** The analysis runs in `AroCommon` over *local copies*, needing each
copy's path and size; the hub exposes no equivalent (`source_files` is internal). Porting
means designing a health endpoint server-side and then building the screen. Do the cheap
items above first.

---

## Deliberate divergences — not gaps

These are not worth porting in either direction, and the audit is more useful for saying so
plainly.

**Cannot exist on web:**

- **Pairing, device topology, export library.** Pairing is a SPAKE2+ handshake meant for a
  person holding two devices; a server-side process cannot complete one. This is also why
  the web client authenticates with the hub's admin token instead.
- **Adding music.** `/v1/imports/*` and `/v1/exchange` are device-token only by design.
- **Bit-perfect and exclusive-mode output, AirPlay routing, output device switching, the
  signal-chain popover.** A browser has no access to any of it.

**Possible but low value:** the gradient wave visualiser could be rebuilt with Web Audio's
`AnalyserNode` on a same-origin stream. It would work; it is decoration.

**Different by design, not behind:**

- ~~**Stats data source.**~~ **Resolved.** macOS used to compute from its own local listening
  history, with the hub's answer as a fallback — two stores, so two possible answers for one
  library. Stats and listening now live only on the hub a client is attached to (a Mac
  hosting its own library reports to the hub it is running). The local recorder, query and
  dashboard use case are gone.
- **Codec fallback.** Web detects formats the browser cannot decode (ALAC, most of this
  library) and transparently requests the hub's Opus transcode. macOS decodes ALAC natively
  and needs none of it.
- **Quality settings.** macOS is *ahead*: it exposes playback quality **and** download
  quality. Web has playback quality only, because it has no downloads.

---

## Suggested order

1. **Radio everywhere on macOS** — the prompt for this audit, and the smallest item here.
2. **More Like This on web** — same endpoint, same idea, immediate payoff.
3. **Playlist detail on web** — closes the one place web is blinder than macOS.
4. **Favourites in the macOS track row** — small, and it feeds Home's intelligence.
5. **Metadata page on web** — the largest win available with zero server work.
6. **Play Next / Add to Queue on macOS** — worth doing slowly; queue invariants.
7. Then reassess: offline downloads and Library Health are both projects, and Library Health
   needs a server design conversation first.
