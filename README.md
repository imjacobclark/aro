# Sonora

A native macOS SwiftUI audio library. Add watched folders from the sidebar and
Sonora recursively discovers playable audio, reads song metadata, and keeps the
library updated as files change.

## Features

- Persisted watched folders with automatic filesystem refresh
- FLAC, ALAC, AAC, MP3, WAV, AIFF, and OGG Vorbis decoding
- Native sample-rate matching, including 96 kHz and 192 kHz DAC output
- Optional exclusive (hog) mode with safe shared-mode fallback
- Gapless playback for consecutive tracks with compatible output formats
- Bit-Perfect and LUFS-normalized playback modes
- Background BS.1770 loudness analysis with a persistent cache
- Combined Songs library and per-folder views
- Native, scrollable table showing title, artist, and duration
- Queueing, seeking, output-device selection, and playback status
- Safe folder removal that never deletes media from disk
- Local-first SQLite library with stable track identities and device locations

## Run

```sh
swift run Sonora
```

To work on the app in Xcode, open `Package.swift`.

## Install as a Mac app

Build, install, and open a release copy in your user Applications folder:

```sh
./scripts/install-app.sh
```

Sonora will appear at `~/Applications/Sonora.app` and can be launched from
Spotlight, Finder, or the Dock like any other Mac app. The build is signed
locally for this Mac. To only create the app bundle without installing it, run:

```sh
./scripts/build-app.sh
```

The resulting bundle is at `dist/Sonora.app`. Drag that bundle into
`/Applications` if you prefer a system-wide installation.

## Playback

Select a song in the table and double-click it, or press Return, to begin
playback. The current table becomes the playback queue. Use the bottom player
bar to pause, skip, seek, or adjust volume.

Open **Sonora → Settings** (or press Command-,) to choose Bit-Perfect or
Normalized playback, select an output device, enable exclusive mode, and set
the loudness target.

Bit-Perfect mode is the default. It uses unity software gain and matches the
track's native sample rate. Tracks with different sample rates require a short
device-reconfiguration gap. Normalized mode analyzes each track before first
play and applies constant gain with a -1 dB peak ceiling.

## Test

```sh
swift test
```

The project uses
[SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine) and its bundled
codec libraries. See `Package.resolved` and the dependency's `LICENSES`
directory for the complete third-party license set.

## Library database

Sonora stores its library index in `Application Support/Sonora/Sonora.sqlite3`.
The filesystem remains the source of audio data, while SQLite stores stable
track IDs, scanned metadata, device-specific file locations, hidden/deleted
state, loudness results, and a future synchronization change log.

The database is loaded before filesystem reconciliation, so the library can
reopen immediately. Open Playback Settings to reveal it in Finder or export a
consistent standalone SQLite copy. Sonora synchronizes logical records rather
than sharing live SQLite/WAL files.
