# Sonora

A native macOS SwiftUI audio library. Add music folders from the sidebar and
Sonora recursively discovers playable audio, reads song metadata, and keeps the
library updated as files change.

## Features

- Persisted watched folders with automatic filesystem refresh
- FLAC, ALAC, AAC, MP3, WAV, AIFF, and OGG Vorbis decoding
- Native sample-rate matching, including 96 kHz and 192 kHz DAC output
- Optional exclusive (hog) mode with safe shared-mode fallback
- Gapless playback for consecutive songs with compatible output formats
- Bit-Perfect and LUFS-normalized playback modes
- Background BS.1770 loudness analysis with a persistent cache
- Combined Songs library and per-folder views
- Native, scrollable table showing title, artist, and duration
- Queueing, seeking, output-device selection, and playback status
- Safe folder removal that never deletes media from disk
- Local-first SQLite library with stable song identities and device locations
- Task-oriented Devices dashboard with secure QR/code pairing
- Isolated local and remote library profiles with one active library at a time
- Streaming, favourites, selected-album, and full-library offline policies

## Repository layout

Sonora is a small monorepo with independently buildable Swift packages:

```text
common/   Cross-platform library models, policies, and use cases
macos/    The macOS app, UI, audio engine, filesystem, and SQLite adapters
```

`SonoraCommon` supports macOS and iOS, but there is intentionally no iOS app
yet. The repository root owns orchestration through `Makefile`; it is not
itself a Swift package.

## Build and run

```sh
make macos build
make macos run
```

You can also build or test every package:

```sh
make all build
make all test
make all run
```

The spaced commands requested above are aliases for conventional targets such
as `make macos-build` and `make all-test`. Run `make help` for the complete
command list.

To work on the app in Xcode, open `macos/Package.swift`. To work directly with
SwiftPM, use `swift build --package-path macos` or
`swift build --package-path common`.

## Install as a Mac app

Build, install, and open a release copy in your user Applications folder:

```sh
make macos install
```

Sonora will appear at `~/Applications/Sonora.app` and can be launched from
Spotlight, Finder, or the Dock like any other Mac app. The build is signed
locally for this Mac. To only create the app bundle without installing it, run:

```sh
make macos app
```

The resulting bundle is at `macos/dist/Sonora.app`. Drag that bundle into
`/Applications` if you prefer a system-wide installation.

## Playback

Select a song in the table and double-click it, or press Return, to begin
playback. The current table becomes the playback queue. Use the bottom player
bar to pause, skip, seek, or adjust volume.

Open **Sonora → Settings** (or press Command-,) to choose Bit-Perfect or
Normalized playback, select an output device, enable exclusive mode, and set
the loudness target.

Bit-Perfect mode is the default. It uses unity software gain and matches the
song's native sample rate. Songs with different sample rates require a short
device-reconfiguration gap. Normalized mode analyzes each song before first
play and applies constant gain with a -1 dB peak ceiling.

## Test

```sh
make check
```

The architecture checks enforce layer direction and keep concrete database,
filesystem, and audio adapters out of application and interface code.

The project uses
[SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine) and its bundled
codec libraries. See `Package.resolved` and the dependency's `LICENSES`
directory for the complete third-party license set. The resolved macOS
dependency graph is stored at `macos/Package.resolved`.

## Library database

Legacy local libraries are migrated from
`Application Support/Sonora/Sonora.sqlite3` to
`Application Support/Sonora/Library Data/Sonora.sqlite3`. Remote library
subscriptions use isolated databases under
`Application Support/Sonora/Libraries/<profile>/Library.sqlite3`.
The filesystem remains the source of audio data, while SQLite stores stable
song IDs, scanned metadata, device-specific file locations, hidden/deleted
state, loudness results, and a future synchronization change log.

The database is loaded before filesystem reconciliation, so the library can
reopen immediately. Open Playback Settings to reveal it in Finder or export a
consistent standalone SQLite copy. Sonora synchronizes logical records rather
than sharing live SQLite/WAL files.

## Architecture

Sonora is split into a platform-neutral package and a capability-owned macOS
application. [Architecture notes](docs/architecture.md) describe the package
boundary, dependency direction, composition root, persistence boundaries, and
automated enforcement.
