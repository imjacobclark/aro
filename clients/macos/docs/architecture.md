# Aro architecture

Aro is a local-first application organized as a small monorepo. The root is
an orchestration workspace rather than a Swift package:

```text
.
├── common/
│   ├── Package.swift
│   ├── Sources/AroCommon/
│   └── Tests/AroCommonTests/
├── macos/
│   ├── Package.swift
│   ├── Sources/Aro/
│   ├── Tests/AroTests/
│   ├── Assets/
│   ├── Packaging/
│   └── scripts/
└── Makefile
```

The macOS package depends on `AroCommon` through a local SwiftPM package
dependency. Common never depends on macOS.

## Package boundary

`AroCommon` contains behavior that can be reused by a future iOS app:

- stable track identity, audio properties, fingerprints, and library
  ordering/deduplication;
- scan metadata/result value objects, folder scan state, and library summary
  formatting and song/audio-property presentation formatters;
- listening and library Stats models, streak calculation, query ports, and
  dashboard loading;
- Library Health entities, recommendations, analysis policy, query port, and
  review use case;
- playback modes, states, output status/device value models, and visualizer
  smoothing;
- playback queue policy, engine contracts/errors/events, preference/history
  ports, listening-session tracking, output-status presentation formatting,
  and loudness analysis contracts;
- scanner, metadata, content-hash, folder-monitoring, and track-state ports;
- loudness-analysis values shared by scanning and playback.

The package uses Foundation only and currently supports macOS 13 and iOS 16.
It contains no SwiftUI, AppKit, Core Audio, AVFoundation, SQLite, filesystem
monitoring, or security-scoped bookmark implementation.

`AroMac` owns everything that integrates with the platform:

- SwiftUI, AppKit, Charts, navigation, visual design, and typography;
- Core Audio and SFBAudioEngine playback;
- file discovery, FSEvents, metadata adapters, and security bookmarks;
- the SQLite database, migrations, repositories, and read projections;
- application composition, resources, app metadata, icon, and bundling.

This creates a useful boundary today without pretending a not-yet-designed iOS
UI or audio stack already exists.

## Capability layers

Inside the macOS app, each capability follows this dependency direction:

```text
Interface -> Application -> Domain
                  ^
                  |
            Infrastructure
```

The source map is:

```text
macos/Sources/Aro/
  App/
  AudioAnalysis/
  DesignSystem/
  Library/
  LibraryHealth/
  Playback/
  Settings/
  Shared/
  Stats/
```

The composition root is
`macos/Sources/Aro/App/Composition/AroApp.swift`. It is the only place
that constructs the database and joins concrete adapters to application
ports.

## Library and persistence

The filesystem remains the source of audio bytes. SQLite is the source of
library state: stable identities, device-local locations, scanned metadata,
user state, listening history, loudness analysis, and the append-only change
log.

The reusable `Song` and fingerprint models live in common. The macOS Library
application layer owns folder scanning use cases and ports. Concrete scanners,
FSEvents monitoring, security-scoped access, metadata readers, and SQLite
repositories remain in macOS infrastructure.

`LibraryDatabase` is opened once by the composition root in full-mutex mode.
Capability adapters receive it through constructor injection. There is no
global database singleton, and no raw SQLite/WAL files are intended for future
device synchronization.

## Library Health and Stats

Library Health business decisions and Stats calculations are cross-platform,
so their entities, policies, query protocols, and use cases live in common.
The macOS package supplies SQLite implementations and SwiftUI views.

This split keeps SQL row decoding and presentation outside the reusable
features while allowing a future client to implement the same query ports
using its own local persistence.

## Playback

Common owns portable playback vocabulary and pure behavior. The macOS package
owns queue orchestration, preferences, session tracking, hardware device
management, the high-resolution engine, real-time metering, listening-history
recording, and the player UI. Output devices carry a stable transport
classification in common; Core Audio maps built-in, USB, Bluetooth, and
AirPlay routes in macOS. Wireless routes intentionally use shared normalized
playback, while wired routes retain the user's bit-perfect and exclusive-mode
preferences.

The visualizer smoother is common because it is deterministic signal shaping;
the AVAudioEngine tap and SwiftUI renderer remain macOS-specific.

## Build orchestration

The root `Makefile` exposes both readable, spaced commands and hyphenated
targets:

```sh
make common build
make macos build
make macos run
make all build
make all run
make check
```

`make all run` builds common and launches the only runnable product, the macOS
app. `AroCommon` is a library and therefore has no standalone runtime.

## Enforcement

`make check` runs both package test suites and the architecture checks. Those
checks reject:

- a root Swift package that obscures package ownership;
- a missing local dependency from macOS to common;
- platform UI, hardware, persistence, or filesystem imports in common;
- macOS-specific compilation branches in common;
- UI, database, or hardware imports in inward macOS layers;
- direct SQLite access from interfaces;
- a global database singleton;
- construction of the database outside the composition root.

Focused common tests cover portable policies and use cases. macOS tests cover
adapters, persistence, scanning, and playback orchestration.
