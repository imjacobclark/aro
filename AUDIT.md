# Aro Codebase Audit

Scope: `common/` (shared `AroCommon` Swift package), `macos/` (SwiftUI client), `server/` (Rust hub/sync server). ~26K LOC Swift + ~54K LOC Rust. Findings only — no fixes applied. Severity reflects realistic exploitability/impact given this is a self-hosted, LAN-facing personal media server, not a multi-tenant public service.

## Summary — top issues by severity

| # | Severity | Issue | Where |
|---|----------|-------|-------|
| 1 | **Critical** | Local admin API has no meaningful transport security: client accepts *any* TLS certificate on the admin channel, and the server binds the admin API on the same `0.0.0.0` socket as the public sync API (no loopback-only listener) | `AroSyncClient.swift` (`PairingTLSDelegate`), `server/crates/aro-server/src/config.rs:62`, `main.rs:224` |
| 2 | **High** | Server's TLS private key is written to disk without restrictive permissions | `server/crates/aro-server/src/main.rs:377-378` |
| 3 | **High** | Admin bearer token compared with non-constant-time `==`, enabling a timing side-channel | `server/crates/aro-server/src/http.rs:732-739, 774-779` |
| 4 | **High** | Synchronous SQLite queries run on the main actor inside 5–30s polling loops, causing potential UI stalls, worst on large libraries | `StatsView.swift:58-63`, `LibraryHealthView.swift:26-31`, `ContentView.swift:159-188` |
| 5 | **High** | Accessibility support is systemically absent: no Dynamic Type anywhere, most complex views have zero accessibility modifiers | app-wide, see Accessibility section |

---

## Security

### 1. [Critical] Admin/export channel has no real transport security
- **Client side:** `AroSyncClient.swift`'s `PairingTLSDelegate` (lines 58-77) accepts *any* server certificate unconditionally. This delegate is used not only for pairing/discovery (a reasonable TOFU trade-off, since SPAKE2+ authenticates the handshake) but also for `localAdminBaseURL` (lines 174-189), which is what `DevicesView.swift:690-696` uses to call `https://127.0.0.1:4848` for library export. The normal synced-session client (`PinnedTLSDelegate`, lines 79-112) does correctly pin on a SHA-256 cert fingerprint — the admin channel is the outlier.
- **Server side:** the admin API is not actually confined to loopback. Default bind is `0.0.0.0:4848` (`server/crates/aro-server/src/config.rs:62`), `Config::validate` explicitly permits unspecified addresses (`config.rs:130-139`), and the admin routes share the same router/socket as the public sync API (`http.rs:35-66`, single `bind_rustls` call at `main.rs:224`). There is a genuinely local-only Unix domain socket (`control.rs:120`, correctly `chmod 0600`), but it's separate from the HTTP admin API the Swift client's `localAdminBaseURL` actually talks to.
- **Combined risk:** anyone on the same network segment who can reach port 4848 and either intercepts or guesses the admin bearer token can act as the server with no certificate validation on the client side, or hit the real server directly since the admin endpoint isn't loopback-restricted.
- **Direction:** either bind the admin HTTP API to loopback only (matching the existing Unix-socket precedent's stated intent), or have the Swift client pin the admin channel's certificate the same way `PinnedTLSDelegate` does for synced sessions.

### 2. [High] TLS private key written without restrictive file permissions
`ensure_certificate` (`server/crates/aro-server/src/main.rs:369-380`) generates a self-signed cert/key with `rcgen` and writes both via plain `std::fs::write` (lines 377-378) with no explicit permissions — they inherit the process umask. This is inconsistent with `Config::save`, which explicitly `chmod`s config to `0o600` (`config.rs:110-119`). A world-readable TLS private key would let any local user (or, if the umask is looser, potentially anyone with filesystem access) impersonate the server.
- **Direction:** set `0o600` on both the cert and key files immediately after writing, matching the pattern already used for `Config::save`.

### 3. [High] Admin token compared with non-constant-time equality
`require_admin` (`server/crates/aro-server/src/http.rs:732-739`) and `require_device_or_admin` (`http.rs:774-779`) compare the bearer token via plain `String`/`&str` `==`. The crate already depends on `subtle` and uses `ConstantTimeEq` correctly for device credentials (`aro-sync-core/src/pairing.rs:343`) — the admin token check is the inconsistent outlier, exposing a timing side-channel that could help an attacker recover the token byte-by-byte over repeated requests.
- **Direction:** compare the admin token with the same `subtle::ConstantTimeEq` already used for device credentials.

### 4. [Medium] No rate-limiting on admin-token-guarded endpoints
`tower-http` is declared as a workspace dependency with the `limit` feature but is never referenced anywhere in the codebase (confirmed via grep across all crates) — it provides no actual protection. Six-digit pairing codes are well-protected separately (`MAX_PAIRING_STARTS = 10`, expiring codes, `aro-sync-core/src/pairing.rs:22,110-113`), but there's no lockout/backoff on repeated failed admin-token attempts.
- **Direction:** add request-rate limiting (the dependency is already present) to admin-token-guarded routes.

### 5. [Medium] Admin token and AcoustID API key stored in UserDefaults
`AroHubService.swift:216-218,259-290` stores the local hub's admin token and AcoustID API key in `UserDefaults` (an unencrypted plist), while pairing credentials elsewhere in the same codebase use the stronger `FileHubCredentialStore` (JSON file, 0700/0600 perms, atomic write, Time-Machine-excluded, `FileHubCredentialStore.swift:27-157`). Inconsistent secret-storage strength within the same app.
- **Direction:** move these secrets into the same credential-store pattern already used for pairing credentials.

### 6. [Low] SQL value interpolated into query string instead of bound
`SQLiteStatsQuery.swift:74-84` interpolates `deviceID` directly into a SQL string (`l.device_id = '\(deviceID)'`) instead of binding it as `?`, even though the identical value is correctly bound via `?` two lines later in the same function. `deviceID` is a locally-generated UUID, not attacker-controlled, so this isn't currently exploitable, but it's an inconsistent, unsafe pattern in an otherwise fully-parameterized codebase.
- **Direction:** bind `deviceID` as a parameter for consistency with the rest of the query layer.

### Confirmed non-issues (checked, no action needed)
- `FileHubCredentialStore`'s deliberate on-disk-not-Keychain design is reasonably protected (0700/0600 perms, atomic write, TM-excluded).
- `AroLibraryExporter.swift` filename sanitization (rejects `/`, `:`, NUL, `.`/`..` components) and SHA-256 blob verification are solid — no path traversal.
- Server-side blob path validation (`aro-sync-core/src/blob.rs:21-41`, hash format + `..`/absolute-path rejection) is consistently applied at every blob-touching store method.
- No ATS exceptions, no hardcoded secrets, no `print()`-leaked credentials (only 3 Swift files use `Logger`, none log secrets); ~8 `unsafe` Rust blocks are all narrow FFI/libc bindings with no obvious memory-safety issue.
- Production-path Rust panics (`.unwrap()`/`.expect()`) are almost entirely in test code or on internally-serialized data / poisoned-mutex cases, not attacker-reachable request handlers.
- Sampled Swift force-unwraps that looked risky on first grep turned out benign on inspection: `AroSyncClient.swift:673,677,691` unwrap a custom `CodingKey` initializer that cannot fail for a `String` input, and `HubControlClient.swift:370`'s `baseAddress!` is only reached when `bytes.count > 0` (loop guard), so it can't be nil there.

---

## Performance

### 1. [High] Synchronous main-thread SQLite polling loops
`LibraryDatabase.withReadConnection`/`withConnection` (`macos/Sources/Aro/Shared/Infrastructure/Persistence/SQLite/LibraryDatabase.swift:76-91`) execute synchronously under an `NSRecursiveLock` with no dispatch to a background queue/actor. `StatsView.swift:58-63` and `LibraryHealthView.swift:26-31` both run `while !Task.isCancelled { <sync DB query>; sleep(5s) }` inside `.task`, which runs on the view's (main) actor — so every 5 seconds while those tabs are visible, the main thread blocks on synchronous SQLite work. `ContentView.swift:159-188` stacks three more main-actor polling loops (30s/15s/15s) on top.
- **Direction:** move these query calls off the main actor (e.g., a background `actor` wrapper around `LibraryDatabase`, or dispatch via `Task.detached`), especially as library size grows.

### 2. [Medium] N+1 query pattern during library rescans
`SQLiteLibraryCatalogRepository.enriching` (`SQLiteLibraryCatalogRepository.swift:78-92`) loops over every `Song` and calls `loudness.analysis(...)` individually for each one missing loudness data — one `prepare`/`step`/`finalize` SQLite query per row (`SQLiteLoudnessAnalysisRepository.swift:12-45`). This runs from `reconcile(songs:folderID:)` after every folder scan/rescan, potentially issuing thousands of individual queries for newly-seen tracks. The database layer already demonstrates the joined alternative (`LibraryDatabase.swift:217-355` uses `LEFT JOIN loudness_analysis`).
- **Direction:** batch the loudness lookup into a single joined/`IN (...)` query instead of per-row calls.

### 3. [Low] Artwork decoding has no downsampling
`ArtworkImageCache` (`AlbumArtworkView.swift:37-55`) is `@MainActor`-bound with a sane 128 MB `NSCache` limit (good — not unbounded), but `NSImage(data:)` decoding (line 51) happens at full native resolution on the main actor regardless of whether the artwork is displayed as a small grid thumbnail or in the larger now-playing panel. No `CGImageSourceCreateThumbnailAtIndex`-style downsampling exists.
- **Direction:** generate/cache a downsampled thumbnail variant for grid views; reserve full-resolution decode for the now-playing panel.

### Confirmed non-issues
- Task lifecycle management is largely fine: `ConnectLibrarySheet.swift:340` stores and cancels its pairing task; `PlaybackController.swift` reassigns task handles (implicit cancellation); most `DevicesView.swift` tasks are user-action-triggered, not per-render.
- Large view *files* (`DevicesView.swift` 907 lines, `ContentView.swift` 559 lines) are not large monolithic `body` blocks — bodies are ~15-180 lines, decomposed into helper subviews.
- Audio/streaming memory handling is sound: `ProgressiveMediaCoordinator.swift` streams to a disk-backed partial file rather than buffering in memory; `HighResolutionPlaybackEngine.swift` uses a fixed 1024-sample buffer.

---

## Bugs & Reliability

### 1. [Medium] No error handling in `OfflineMusicSettingsSheet`
`OfflineMusicSettingsSheet.swift` has no `catch`, `alert`, or failure-state UI anywhere in the file. Its `save()` (line 315) calls `registry.update(updated)` (`LibraryProfileRegistry.swift:275-283`), which persists silently with no return value/throw — if the underlying save fails, the user sees no indication their offline-storage settings weren't actually saved.
- **Direction:** surface a failure path from `registry.update`/its underlying `save()`, and show it in this sheet the way `DevicesView.swift` surfaces errors via `statusMessage`.

### 2. [Low] Inconsistent error-surfacing pattern across sheets
`DevicesView.swift` and `ConnectLibrarySheet.swift` both funnel caught errors into a plain `statusMessage: String?` rendered as inline text rather than a native `.alert`, while `DevicesView.swift` also defines a dedicated `DevicesError: LocalizedError` enum (line 901) that isn't consistently used for user-facing presentation. Not a bug per se, but the inconsistency makes failures easy to miss (inline text vs. modal alert) and harder to extend uniformly.
- **Direction:** standardize on one error-presentation pattern (likely `.alert` bound to a typed error) across the Devices/Sync sheets.

### Confirmed non-issues
- Zero `try!`/`as!` anywhere in the Swift codebase. Of 13 genuine force-unwraps, the ones sampled in `DevicesView.swift:693-694,757` and the Sync networking files (see Security section) are all guarded or provably safe on inspection — the grep-level count overstates real risk.
- No `TODO`/`FIXME`/`HACK` markers anywhere in `macos/Sources/Aro`.
- Recent commit history (last ~20 commits) clusters around Library/Playback/Devices/Sync connection-repair bugs — consistent with these being the highest-touched, highest-complexity modules; no new distinct bug classes found beyond what's already been fixed or is listed above.

---

## Accessibility

**Systemic gap, not a spot issue.** Of 37 SwiftUI view files under `macos/Sources/Aro/**/UI`, only 14 contain any accessibility modifier (`accessibilityLabel`/`Hint`/`Element`/`Value`), and most of those 14 have just one or two modifiers rather than comprehensive coverage — roughly a 38% file-touch rate that overstates actual depth of support.

- **[High]** Zero usage anywhere of `dynamicTypeSize`, `@ScaledMetric`, or `scaledMetric` — the app has no Dynamic Type support at all, meaning users who rely on larger system text sizes get no accommodation anywhere in the UI.
- **[Medium]** `ConnectLibrarySheet.swift`, `OfflineMusicSettingsSheet.swift`, and most of `DevicesView.swift` (907 lines) — all complex, state-heavy sheets — have no accessibility modifiers at all, making them effectively unusable with VoiceOver.
- Files with at least partial support: `AppSettingsButton.swift`, `LibraryHealthRecommendationCard.swift`, `NavigationSidebar.swift`, `FolderRow.swift`, `PlayerBar.swift`, `GradientWaveVisualizer.swift`, `NowPlayingArtworkPanel.swift`, `AlbumsView.swift`, `AlbumArtworkView.swift`, `ArtistsView.swift`, `LibraryAlbumSection.swift`, `LibrarySearchField.swift`, `AddDeviceSheet.swift`, `PairingQRCodeView.swift`.
- **Direction:** prioritize VoiceOver labels/hints for the three unsupported sheets first (they gate core flows — connecting a library, managing offline storage, managing devices), then add baseline Dynamic Type support to text-heavy views before broader modifier coverage.

---

## Testing Gaps

- `common/Tests/AroCommonTests`: 5 files / 802 LOC — covers `LibraryHealthAnalyzer`, `LibraryModels`, Stats dashboard loading, Playback application logic, Sync.
- `macos/Tests/AroTests` + `Tests/Standalone`: 26 files / 4,216 LOC — covers AudioAnalysis, Devices, Library (AppKit table, scanner, application), Persistence, Playback (meter relay, now-playing, controller, safety, progressive media, streaming input, preferences), Sync (discovery, credential store, hosting prefs, pairing integration, persistence, protocol dates).
- **No dedicated tests found for:** Settings, Stats, App/Composition (`AroApp.swift`, `LibraryRuntime.swift`), Artist, Album, or DesignSystem modules. Given the main-thread polling loops (Performance #1) and the admin-channel security findings (Security #1-3) both live in code paths without direct test coverage identified here, these are reasonable priorities for new tests alongside any fixes.
