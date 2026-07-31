# Listening Intelligence Roadmap

How Aro's auto-generated playlists get from "derived from play counts and
MusicBrainz tags" (shipped) to the kind of personal, contextual, audio-aware
programming Spotify and Apple Music do — without ever sending listening data or
audio to a third party.

## Ground rules

These follow from decisions already made and shipped; new work must not undo
them.

1. **The hub generates, clients render.** All derived features — playlists,
   analytics, tag derivation — live in `server/crates/` (`aro-server`'s
   `playlists` module today). Clients fetch results and map them onto their
   local catalogs; they never compute their own. One hub, one answer, every
   device sees the same Home screen.
2. **Content hash is the only shared key.** Hub track ids and client library
   ids never coincide. Every feature, signal, and playlist crosses the wire
   keyed by content hash.
3. **Heavy computation happens where the audio bytes are.** The hub may be a
   Raspberry Pi (mercury is: armv7, ~1 GB RAM). The loudness pipeline already
   set the precedent: the capable device analyzes, the compact *result* syncs
   to the hub as a content-hash-keyed CRDT operation (`entity_type:
   "loudness"`), and the hub consumes numbers, not waveforms. Tiers 2 and 3
   reuse this shape exactly.
4. **Honest labels.** A playlist's subtitle says what actually drives it
   ("tagged via MusicBrainz", "measured tempo"). No fabricated
   personality.

## Where we are (shipped)

- `listening_events` on the hub: per-session `started_at`, `ended_at`,
  `listened_seconds`, `completed`, synced from every client.
- Favourites in CRDT track state, materialized into `tracks.metadata`.
- Background identification derives canonical genres and a small mood
  vocabulary (`relaxed`, `energetic`, `feelgood`, `mellow`) from MusicBrainz
  folksonomy tags (`aro-track-id`'s `canonicalize_tags`), stored in
  `identification_results`.
- `aro-server/src/playlists.rs` generates: Recently Loved, Heavy Rotation,
  mood mixes, Recently Played, Deep Cuts — deterministic daily shuffle, served
  over `/v1/playlists` and the control socket.

Every tier below is additive to this pipeline: new *inputs* into
`playlist_seeds()`, new *recipes* in `playlists.rs`.

**Status: all three tiers below are implemented and tested** (server-side
Rust, `aro-server`'s test suite green end to end) and wired into the shipped
Home screen. Remaining: mercury deploy of this build, then background
analysis needs to actually run against the real library before Workout
Mix/Wind Down/Daily Mix/Radio have data to show (they degrade gracefully to
"not shown yet" until then, per the minimum-track-count gates below).

---

## Tier 1 — Behavioural signals (no ML, mostly SQL)

The largest share of what makes commercial recommendations feel smart is not
ML — it is capturing negative signals, recency, and context that we currently
throw away.

### New data capture

| Signal | Where it comes from | Change required |
|---|---|---|
| **Skip events** | `PlaybackController.next()` invoked before ~50% / 30s of a track | Client: record `skipped` on the listening session (session already exists; add a flag + position). Syncs through the existing `listening_session` op — hub adds a `skipped` column, same idempotent `ALTER TABLE` pattern as `completed`. |
| **Completion ratio** | Already derivable: `listened_seconds / duration` | Hub-side only; duration is in `tracks.metadata`. No capture change. |
| **Time-of-day / day-of-week buckets** | Already captured (`started_at`) | Hub-side aggregation only. |
| **Session co-occurrence** | Tracks whose sessions share a device and fall within the same listening window | Hub-side only: window `listening_events` by device + gap threshold (e.g. 30 min) to reconstruct sessions, build a track→track transition tally. |
| **Decayed affinity** | Play counts weighted by recency (exponential half-life, e.g. 45 days) | Hub-side only: replaces raw `COUNT(*)` in `playlist_seeds()`. |

### New playlists unlocked

- **Forgotten Favourites** — high historic affinity, zero plays in 90 days.
  The single highest-value/effort ratio on this roadmap.
- **Fresh Finds** — added in the last 30 days, unplayed or barely played.
- **Morning Rotation / Late Night** — the labels the reference design faked,
  now real: tracks whose plays skew into the requester's morning/evening
  buckets. (Requires client to send its UTC offset with the playlists request,
  or hub stores per-device offsets from sync metadata.)
- **Smarter existing playlists** — Heavy Rotation ranked by decayed affinity
  with skip-penalty; Deep Cuts excludes high-skip tracks rather than treating
  never-played and always-skipped alike.
- **Smart shuffle / radio v0** — order queues by walking the co-occurrence
  graph from a seed track instead of uniform shuffle. (Client change: a "play
  radio from this song" action that requests a hub-generated queue.)

### Effort & risk

Days, not weeks. One new client-side signal (skips), everything else is
server-side SQL + recipe work with unit tests alongside the existing
`playlists.rs` tests. No schema risk beyond additive columns. Ship
independently of Tiers 2–3.

---

## Tier 2 — Measured audio features (DSP, no neural nets)

MusicBrainz folksonomy is sparse and third-party. Tempo and energy can be
*measured* from the audio itself, cheaply, using classic signal processing —
no models, no training data.

### Features (per track, a handful of floats)

- **Tempo (BPM)** — onset detection + autocorrelation.
- **Energy** — RMS distribution (mean + variance says "steady chill" vs
  "quiet-loud-quiet").
- **Brightness** — spectral centroid/rolloff (dark ambient vs bright pop).
- **Dynamic range** — already adjacent to the loudness analyzer's data.
- **Danceability proxy** — beat-strength regularity from the onset envelope.

### Architecture: clone the loudness pipeline

This is deliberately *not* new architecture:

1. Client-side `AudioFeaturesAnalyzer` next to `LoudnessAnalysisService`
   (Accelerate/vDSP on the Mac — the decode path already exists for loudness).
   The hub can also run the same analysis in Rust for tracks only it holds
   (`aro-track-id` already decodes audio for fingerprinting), gated to
   trickle on weak hardware.
2. Results sync as a new CRDT entity (`entity_type: "audio_features"`), keyed
   by content hash + algorithm version — the exact shape `loudness` ops use,
   including the version-based re-analysis story.
3. Hub stores an `audio_features` table; `playlist_seeds()` joins it.

**Implemented as:** `aro_track_id::audio_features` (pure-Rust `rustfft` +
hand-rolled mel filterbank/MFCC/chroma/onset-autocorrelation tempo — see the
crate doc comment), a background `AudioFeatureQueue` cloning
`LoudnessQueue`'s shape exactly, wired into `SourceManager` the same way
identification/loudness are. One deliberate simplification from the plan
above: analysis is **hub-only** for now (no client-side Swift analyzer, no
CRDT sync) — `audio_features` is a plain local hub table, not a synced CRDT
entity, since the hub already has direct file access to everything it scans.
Revisit if a "client analyzes what the hub can't reach" case actually comes
up.

### New playlists unlocked

- **Workout Mix** (`workout-measured`) / **Wind Down** (`wind-down-measured`)
  — measured tempo/energy/brightness thresholds, ordered slowest-to-fastest
  (tempo-coherent). Distinct from the Tier 1 MusicBrainz-tagged mood mixes
  (`mood-energetic`/`mood-relaxed`), which still exist independently.
- **Tempo-coherent ordering** — implemented for the two mixes above (sorted
  by `tempo_bpm` ascending) rather than as a generic apply-to-any-playlist
  utility.
- Energy arcs (ramping mixes) — not implemented; the vector/scalar features
  needed for it exist, but no recipe uses it yet.

### Effort & risk

Delivered in one pass alongside Tier 3 (they share one analyzer). Real risk
turned out to be getting the DSP right, not performance — validated with unit
tests against synthetic sine waves and a synthetic click track (tempo
recovered within 6 BPM of a known 120 BPM click track; chroma correctly peaks
at A440's pitch class).

---

## Tier 3 — Similarity embeddings (engineered features, no ML runtime)

The genuinely Spotify-shaped capability: knowing two tracks *sound similar*
without any tags at all — **without** a neural network, a model file, or a
platform-specific ML framework.

**Why not CoreML/ONNX/a pretrained embedding model:** analysis has to run
identically wherever the hub happens to be — mercury today (a Pi-class ARM
board), a Mac, and eventually Windows. CoreML is Apple-only. A learned
embedding model (OpenL3/MusiCNN-class) needs an inference runtime
(CoreML/ONNX Runtime/TFLite), a model file to ship and license, and enough
headroom to run it — a weak board like a Raspberry Pi 2 (quad-core
Cortex-A7, 1 GB RAM, no GPU) is a poor place to run even a small quantized
model at library scale. That's a dependency and a performance cliff this
project doesn't need.

### Approach: engineered feature vectors, not learned ones

This is classic MIR (music information retrieval) — how audio similarity
worked before deep learning, and it composes directly with Tier 2 instead of
adding a second pipeline:

- **One analysis pass, one crate, richer output.** The Tier 2 analyzer
  already decodes the track and computes tempo/energy/brightness/dynamic
  range. Tier 3 extends that same pass to also emit:
  - **MFCCs** (mel-frequency cepstral coefficients, ~13 bands, mean +
    variance) — the standard hand-engineered descriptor of timbre.
  - **Chroma** (12-bin pitch-class profile) — harmonic/tonal content.
  - The Tier 2 scalars (tempo, energy, brightness, dynamic range,
    danceability proxy), concatenated in.
  - Total: a fixed-length vector (~40–60 floats) per track — pure arithmetic
    over an FFT that's already being computed for Tier 2, no matrix
    multiplies against a model's weights, no framework dependency beyond an
    FFT crate. Runs identically on ARM (Pi 2 or better), x86/Apple Silicon
    macOS, and Windows, because it's just Rust doing math.
  - Syncs exactly like Tier 2's features: a CRDT entity keyed by content hash
    + algorithm version, so a future revision to the feature extraction
    re-triggers analysis the same way a loudness/tempo algorithm bump would.
- **Hub-side clustering & similarity** — k-means (or simple
  nearest-neighbour; a personal library is thousands of tracks, not millions)
  over these vectors in `playlists.rs`'s crate. Plain Rust arithmetic on
  small float vectors — trivial for even a Pi 2 to do at this scale, unlike
  running a model.

*If a future case genuinely needs a learned embedding, the honest escape
hatch is [`tract`](https://github.com/sonos/tract) (Sonos's pure-Rust ONNX
inference engine, no C++/CoreML/platform lock-in, built for exactly this kind
of small ARM device) rather than CoreML — but that's a bigger dependency and
isn't needed to hit every playlist type below.*

**Implemented as:** `AudioFeatures::vector()` (43 floats: 5 scalars + 26 MFCC
mean/variance + 12 chroma) feeding a deterministic k-means (Lloyd's
algorithm, seeded centroid init so results are reproducible, `playlists.rs`)
and a nearest-neighbour `radio()` function — both unit-tested (k-means
recovers 4 synthetically well-separated groups exactly; radio ranks a close
neighbour ahead of a far one and excludes a heavily-skipped-but-close track).

### New playlists unlocked

- **Daily Mix 1–4** (`daily-mix-1`…`daily-mix-4`, shipped) — k-means over the
  vector, `DAILY_MIX_COUNT = 4`, gated behind `DAILY_MIX_MIN_TRACKS = 32`
  analyzed tracks so tiny/sparse libraries don't get noise clusters. Numbered
  by descending cluster-total decayed affinity, so "Daily Mix 1" is built
  from the listener's most-played cluster — the "blended with Tier 1
  affinity" idea above, realized as ordering rather than a scoring blend.
  Tracks within each mix are further ordered by affinity. Not yet
  implemented: topping up a mix with low-play same-cluster tracks for
  discovery (currently a mix is exactly its cluster membership).
- **Seed-track radio (real, shipped)** — `playlists::radio(seeds, seed_hash,
  limit)`, exposed via the control socket (`Radio` command) and
  `GET /v1/radio/{hash}`, wired end-to-end to a "Start Radio" context-menu
  action on Home's track rows and playlist cards. Ordered by vector distance
  (which already incorporates the Tier 2 tempo/energy scalars, so no separate
  coherence-ordering pass was needed) and filters out tracks skipped more
  than `RADIO_MAX_SKIP_RATE` (70%) of their plays.
- **"Sounds like" browsing** — the `radio()` primitive supports this; only
  the "Start Radio" entry point shipped so far, not a dedicated browsing UI.
- **Cold-start coverage** — works as designed: `radio`/Daily Mix consider any
  track with a stored `audio_features` row, independent of play count or
  MusicBrainz identification.

### Effort & risk

Delivered together with Tier 2 (one analyzer, one crate). Real remaining
unknown, as anticipated: clustering/similarity *quality* against a real,
messy library — the synthetic tests prove the math works, not that a k-means
cluster over MFCC/chroma feels musically coherent to a listener. Validate
against mercury's actual library once analysis has run, and consider Tier 1
skip-rate as a correction signal if clusters feel off.

---

## Sequencing

```
Tier 1  ──────────────►  ships alone, immediately useful
Tier 2  ─────► needs nothing from Tier 1 (but its playlists get better with it)
Tier 3  ─► literally extends Tier 2's analyzer output; wants Tier 1 for affinity blending
```

Recommended order: **1 → 2 → 3**, shipping each tier's playlists as it lands.
Tiers 2 and 3 are one analysis pass in practice (the same decode produces
scalar features and the fuller similarity vector), so they're natural to
build together once either is scheduled. Every tier keeps the same contract:
hub generates from content-hash-keyed seeds, `/v1/playlists` + control socket
serve the result, clients map hashes onto their catalogs and render. Nothing
about the Home screen UI needs to change as the recipes underneath it get
smarter.

## Explicit non-goals

- No third-party recommendation APIs, no telemetry leaving the user's
  devices/hub — listening data is the most personal data Aro holds.
- No collaborative filtering across users: Aro is single-listener by design;
  similarity comes from the audio and one person's behaviour.
- No opaque "algorithm": every playlist keeps an honest subtitle naming its
  actual signal.
