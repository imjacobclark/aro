import Darwin
import Foundation
import OSLog
import AroCommon

enum HubControlError: LocalizedError {
    case emptyResponse
    case invalidResponse
    case rejected(String)
    case incompatibleHelper
    case timedOut

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            "The Aro Background Service closed its control connection without responding."
        case .invalidResponse:
            "The Aro Background Service returned an invalid control response."
        case .rejected(let message):
            "The Aro Background Service rejected the request: \(message)"
        case .incompatibleHelper:
            "The running Aro Background Service is from an older app build."
        case .timedOut:
            "The Aro Background Service did not respond in time."
        }
    }
}

struct HubPairingWindow: Sendable {
    let code: String
    let expiresAt: Date
}

struct HubControlStatus: Sendable {
    let hubID: UUID
    let displayName: String
    let pairingAvailable: Bool
    let sequence: UInt64
    let storageMode: String
}

struct ControlledHubDevice: Identifiable, Codable, Sendable {
    let deviceID: UUID
    let name: String
    let deviceType: String?
    let pairedAt: Date?
    let revokedAt: Date?
    let lastSeenAt: Date?
    let lastSyncedAt: Date?
    let offlineTrackCount: UInt64?
    let canContribute: Bool?

    var id: UUID { deviceID }
    var allowsContributions: Bool { canContribute ?? false }
}

struct ControlledPairingRequest: Identifiable, Codable, Sendable {
    let requestID: UUID
    let deviceID: UUID
    let deviceName: String
    let deviceType: String?
    let expiresAt: String

    var id: UUID { requestID }
}

struct ControlledSourceFolder: Identifiable, Codable, Sendable {
    let sourceID: UUID
    let name: String
    let path: String
    let available: Bool
    let watching: Bool
    let lastScanAt: String?
    let lastError: String?
    let songCount: UInt64
    let missingCount: UInt64

    var id: UUID { sourceID }
}

struct IdentificationStatus: Codable, Sendable {
    let queued: UInt64
    let inFlight: Bool
    let processed: UInt64
    let failed: UInt64
    let lastError: String?
}

/// A file to (re-)identify, addressed by content hash and its absolute on-disk path
/// — not a track id. `aro-server`'s own `hub_track_id`s and this app's local track
/// ids are generated independently and never coincide; content hash and a real path
/// are the only things the server needs to fingerprint and identify a file it may
/// never have seen before.
struct IdentificationTarget: Sendable {
    let contentHash: String
    let path: String
}

struct IdentificationResult: Codable, Sendable {
    let contentHash: String
    let title: String?
    let artist: String?
    let album: String?
    let artworkURL: String?
    let musicbrainzRecordingID: String?
    let acoustidID: String?
    let identifiedAt: Int64
    /// JSON-array-encoded text (e.g. `["dream pop","shoegaze"]`), matching the server's
    /// `IdentificationResult.musicbrainz_genres` storage — decoded into `[String]` only at
    /// `Song` hydration time (see `SQLiteLibraryCatalogRepository`), same as `moodTags`.
    let musicbrainzGenres: String?
    /// JSON-array-encoded text of up to 2 canonical mood tags (see
    /// `aro_track_id::musicbrainz::canonicalize_tags` server-side).
    let moodTags: String?
}

/// One auto-generated playlist as computed by the hub (see `aro-server`'s `playlists`
/// module) — the server is the canonical generator; this app only maps the returned
/// content hashes onto its local catalog and renders. Hashes the local library doesn't
/// hold are simply dropped.
/// Mirrors `aro-server`'s `playlists::PlaylistKind` — a presentation hint only, `id`
/// remains the stable per-playlist identity.
enum ServerPlaylistKind: String, Codable, Sendable, Equatable {
    case forYou = "for_you"
    case recentlyPlayedTrack = "recently_played_track"
    case recentlyPlayedAlbum = "recently_played_album"
    case mood
    case artistMix = "artist_mix"
    case favouriteArtist = "favourite_artist"
    case hitsByYear = "hits_by_year"
    case replayMonth = "replay_month"
    case replayAllTime = "replay_all_time"
    case lostAlbum = "lost_album"
    case timeCapsule = "time_capsule"
    /// Any kind this build doesn't recognize — a newer hub adding a kind must not
    /// break an older client. Without this, `Decodable` synthesis throws on the first
    /// unknown value, and since playlists decode as one array that failure takes out
    /// *every* playlist, blanking Home entirely rather than hiding one unfamiliar
    /// row. Home routes unknown kinds through its generic mix card, so they still
    /// render and play; they simply don't get bespoke placement.
    case unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ServerPlaylistKind(rawValue: raw) ?? .unknown
    }
}

struct ServerGeneratedPlaylist: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let contentHashes: [String]
    let kind: ServerPlaylistKind
    /// Seconds since epoch of the most recent play among `contentHashes`, or `nil` if
    /// none of them have ever been played.
    let lastPlayedAt: Double?
}

struct HubControlClient: Sendable {
    static let controlProtocolVersion = 9

    private static let logger = Logger(
        subsystem: "com.othyn.aro",
        category: "HubControl"
    )

    /// Applied as `SO_RCVTIMEO`/`SO_SNDTIMEO` on the raw control socket. Without
    /// this, a hung or crash-looping local `aro-server` (see the LaunchAgent
    /// code-signing issue this app has hit before) leaves `sendValue` blocked on a
    /// blocking `read`/`write` syscall forever — Swift concurrency's own task
    /// cancellation can't interrupt a blocking POSIX call, so the timeout has to be
    /// enforced by the kernel at the socket level, not by racing a `Task.sleep`.
    private static let socketTimeout = timeval(tv_sec: 10, tv_usec: 0)

    let socketURL: URL

    func verifyCompatibility() async throws {
        let result = try await send(["command": "status"])
        guard let version = result["control_protocol_version"] as? Int,
              version == Self.controlProtocolVersion else {
            throw HubControlError.incompatibleHelper
        }
    }

    func status() async throws -> HubControlStatus {
        let result = try await send(["command": "status"])
        guard let hubIDText = result["hub_id"] as? String,
              let hubID = UUID(uuidString: hubIDText),
              let displayName = result["display_name"] as? String,
              let pairingAvailable = result["pairing_available"] as? Bool,
              let sequence = result["sequence"] as? Int,
              let storageMode = result["storage_mode"] as? String else {
            throw HubControlError.invalidResponse
        }
        return HubControlStatus(
            hubID: hubID,
            displayName: displayName,
            pairingAvailable: pairingAvailable,
            sequence: UInt64(sequence),
            storageMode: storageMode
        )
    }

    func openPairing() async throws -> HubPairingWindow {
        let result = try await send(["command": "open_pairing"])
        guard let code = result["code"] as? String,
              let expiresInSeconds = result["expires_in_seconds"] as? Int else {
            throw HubControlError.invalidResponse
        }
        return HubPairingWindow(
            code: code,
            expiresAt: Date().addingTimeInterval(
                TimeInterval(expiresInSeconds)
            )
        )
    }

    func devices() async throws -> [ControlledHubDevice] {
        let result = try await sendValue(["command": "devices"])
        let data = try JSONSerialization.data(withJSONObject: result)
        let decoder = JSONDecoder.aroSyncProtocol()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ControlledHubDevice].self, from: data)
    }

    func pendingPairingRequests() async throws -> [ControlledPairingRequest] {
        let result = try await sendValue([
            "command": "pending_pairing_requests"
        ])
        let data = try JSONSerialization.data(withJSONObject: result)
        let decoder = JSONDecoder.aroSyncProtocol()
        return try decoder.decode([ControlledPairingRequest].self, from: data)
    }

    func approvePairing(
        requestID: UUID,
        approve: Bool,
        canContribute: Bool = false
    ) async throws {
        _ = try await sendValue([
            "command": "approve",
            "request_id": requestID.uuidString,
            "approve": approve,
            "can_contribute": canContribute,
        ])
    }

    func setContribution(deviceID: UUID, allowed: Bool) async throws {
        _ = try await send([
            "command": "set_contribution",
            "device_id": deviceID.uuidString,
            "allowed": allowed,
        ])
    }

    func removeTrack(contentHash: String) async throws {
        _ = try await send([
            "command": "remove_track",
            "content_hash": contentHash,
        ])
    }

    func revoke(deviceID: UUID) async throws {
        _ = try await send([
            "command": "revoke",
            "device_id": deviceID.uuidString,
        ])
    }

    func importFolder(path: String, mode: HubImportMode) async throws -> Int {
        let result = try await send([
            "command": "import",
            "path": path,
            "mode": mode.rawValue,
        ])
        guard let imported = result["imported_tracks"] as? Int else {
            throw HubControlError.invalidResponse
        }
        return imported
    }

    func folders() async throws -> [ControlledSourceFolder] {
        let result = try await sendValue(["command": "folders"])
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder.aroSyncProtocol().decode(
            [ControlledSourceFolder].self,
            from: data
        )
    }

    func scanFolder(_ sourceID: UUID? = nil) async throws {
        var command: [String: Any] = ["command": "scan_folder"]
        if let sourceID {
            command["source_id"] = sourceID.uuidString
        }
        _ = try await send(command)
    }

    func removeFolder(_ sourceID: UUID) async throws {
        _ = try await send([
            "command": "remove_folder",
            "source_id": sourceID.uuidString,
        ])
    }

    /// Enqueues one or more files for background (re-)identification against
    /// AcoustID/MusicBrainz. Used for both "Sync Track Data" (one file) and "Sync
    /// Album Data" (every file in the album) — the server has no album grouping of
    /// its own, so the full set is resolved client-side.
    func identifyTracks(_ targets: [IdentificationTarget]) async throws {
        _ = try await send([
            "command": "identify_tracks",
            "tracks": targets.map {
                ["content_hash": $0.contentHash, "path": $0.path]
            },
        ])
    }

    func identificationStatus() async throws -> IdentificationStatus {
        let result = try await sendValue(["command": "identification_status"])
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder.aroSyncProtocol().decode(IdentificationStatus.self, from: data)
    }

    /// Results recorded after `after` (exclusive), oldest first. `after` should be
    /// the `identifiedAt` of the last result already applied — pass `0` to fetch
    /// everything the server has ever identified.
    func identificationResults(after: Int64) async throws -> [IdentificationResult] {
        let result = try await sendValue([
            "command": "identification_results",
            "after": after,
        ])
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder.aroSyncProtocol().decode([IdentificationResult].self, from: data)
    }

    /// The hub's current auto-generated playlists — local-socket equivalent of the
    /// remote `/v1/playlists` endpoint (`AroSyncClient.playlists(credential:)`).
    /// `utcOffsetMinutes` (this device's local UTC offset, positive east of UTC)
    /// scopes Morning Rotation/Late Night to this device's timezone.
    func playlists(utcOffsetMinutes: Int = TimeZone.current.secondsFromGMT() / 60) async throws -> [ServerGeneratedPlaylist] {
        let result = try await sendValue([
            "command": "playlists",
            "utc_offset_minutes": utcOffsetMinutes,
        ])
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder.aroSyncProtocol().decode(
            [ServerGeneratedPlaylist].self,
            from: data
        )
    }

    /// Tier 3 "seed-track radio" (see `aro-server`'s `playlists::radio`) — the tracks
    /// most similar to `contentHash` by measured audio-feature vector, nearest first,
    /// with `contentHash` itself in front. `nil` if the seed hasn't been analyzed yet.
    func radio(
        contentHash: String,
        limit: Int = 30
    ) async throws -> ServerGeneratedPlaylist? {
        let result = try await sendValue([
            "command": "radio",
            "content_hash": contentHash,
            "limit": limit,
        ])
        if result is NSNull { return nil }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder.aroSyncProtocol().decode(ServerGeneratedPlaylist.self, from: data)
    }

    func setSetting(key: String, value: Bool) async throws {
        _ = try await send([
            "command": "set_setting",
            "key": key,
            "value": value,
        ])
    }

    func boolSetting(key: String) async throws -> Bool? {
        let result = try await send([
            "command": "setting",
            "key": key,
        ])
        return result["value"] as? Bool
    }

    func setSetting(key: String, value: String) async throws {
        _ = try await send([
            "command": "set_setting",
            "key": key,
            "value": value,
        ])
    }

    func stringSetting(key: String) async throws -> String? {
        let result = try await send([
            "command": "setting",
            "key": key,
        ])
        return result["value"] as? String
    }

    /// Reads a single `aro.toml` field by dotted key (e.g. `dashboard.bind`) —
    /// see `setConfig(key:value:)` for why the app never hand-writes the file
    /// itself. Bools decode as `"true"`/`"false"` explicitly: `JSONSerialization`
    /// bridges a JSON boolean to `NSNumber`, whose default string interpolation
    /// prints `"1"`/`"0"`, which would silently fail to round-trip through the
    /// server's `bool::from_str` on the next `setConfig` call.
    func configValue(key: String) async throws -> String {
        let result = try await send(["command": "get_config", "key": key])
        switch result["value"] {
        case let bool as Bool:
            return bool ? "true" : "false"
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            throw HubControlError.invalidResponse
        }
    }

    /// Writes a single `aro.toml` field through the server's own validated
    /// `Config::set_field`, so this app never re-implements `Config`'s shape or
    /// hand-writes TOML. Never applies live — the caller is responsible for
    /// restarting the Background Service (see `AroHubService.restartForUpgrade()`)
    /// if the change should take effect immediately.
    func setConfig(key: String, value: String) async throws {
        _ = try await send([
            "command": "set_config",
            "key": key,
            "value": value,
        ])
    }

    /// Verifies every blob in the local hub's store still hashes to what was
    /// recorded for it, returning the count checked and any corrupt/missing
    /// content hashes.
    func verifyLibrary() async throws -> (verified: Int, failures: [String]) {
        let result = try await send(["command": "verify"])
        guard let verified = result["verified"] as? Int else {
            throw HubControlError.invalidResponse
        }
        let failures = result["failures"] as? [String] ?? []
        return (verified, failures)
    }

    /// Deletes an unreferenced blob by content hash — intended to be reachable
    /// only from a hash a prior `verifyLibrary()` call named, not as a general
    /// free-text purge.
    func purgeBlob(hash: String) async throws -> Bool {
        let result = try await send(["command": "purge", "hash": hash])
        return result["removed"] as? Bool ?? false
    }

    /// Resolves a content hash to its on-disk path for local playback — the
    /// same-machine equivalent of downloading a blob, without reading its bytes
    /// through the socket first (see `blob(hash:)`, which is appropriate for
    /// artwork, not for opening a song in the playback engine).
    func trackLocation(hash: String) async throws -> String {
        let result = try await send(["command": "track_location", "hash": hash])
        guard let path = result["path"] as? String else {
            throw HubControlError.invalidResponse
        }
        return path
    }

    /// Pulls this hub's own operation log after `afterSequence`, oldest first —
    /// the local-profile analogue of `AroSyncClient.exchange()`'s pull side, for
    /// a same-machine client replicating its library from its own hub instead of
    /// scanning independently. Decodes into the same `SequencedSyncOperation`
    /// `.remote` profiles already apply via `SQLiteSyncOperationStore.applyRemote`.
    func changesAfter(_ afterSequence: UInt64, limit: UInt32 = 500) async throws -> [SequencedSyncOperation] {
        let result = try await sendValue([
            "command": "changes_after",
            "after_sequence": afterSequence,
            "limit": limit,
        ])
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder.aroSyncProtocol().decode([SequencedSyncOperation].self, from: data)
    }

    /// Reads a blob's bytes off the local hub's own store over the control
    /// socket — used for cached artwork (`IdentificationResult.artworkURL`
    /// points at `/v1/blobs/{hash}` since aro-track-id started caching Cover
    /// Art Archive images server-side) when this Mac is running the hub whose
    /// results it just pulled, so no HTTP round-trip or device credential is
    /// needed for data it already has local filesystem access to.
    func blob(hash: String) async throws -> Data {
        let result = try await send([
            "command": "blob",
            "hash": hash,
        ])
        guard let base64 = result["data_base64"] as? String,
              let data = Data(base64Encoded: base64) else {
            throw HubControlError.invalidResponse
        }
        return data
    }

    private func send(
        _ command: [String: Any]
    ) async throws -> [String: Any] {
        let result = try await sendValue(command)
        guard let object = result as? [String: Any] else {
            throw HubControlError.invalidResponse
        }
        return object
    }

    private func sendValue(
        _ command: [String: Any]
    ) async throws -> Any {
        let path = socketURL.path
        let commandName = command["command"] as? String ?? "unknown"
        let request = try JSONSerialization.data(withJSONObject: command)
        let started = ContinuousClock.now
        Self.logger.debug(
            "control command started: \(commandName, privacy: .public)"
        )
        let response: Data
        do {
            response = try await Task.detached {
                let descriptor = socket(
                    AF_UNIX,
                    SOCK_STREAM,
                    0
                )
                guard descriptor >= 0 else {
                    throw POSIXError(.ENOTCONN)
                }
                defer { Darwin.close(descriptor) }

                var timeout = Self.socketTimeout
                setsockopt(
                    descriptor, SOL_SOCKET, SO_RCVTIMEO,
                    &timeout, socklen_t(MemoryLayout<timeval>.size)
                )
                setsockopt(
                    descriptor, SOL_SOCKET, SO_SNDTIMEO,
                    &timeout, socklen_t(MemoryLayout<timeval>.size)
                )

                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                let pathBytes = Array(path.utf8) + [0]
                guard pathBytes.count <= MemoryLayout.size(
                    ofValue: address.sun_path
                ) else {
                    throw POSIXError(.ENAMETOOLONG)
                }
                withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                    buffer.copyBytes(from: pathBytes)
                }
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(
                            descriptor,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_un>.size)
                        )
                    }
                }
                guard connected == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOTCONN)
                }

                try request.withUnsafeBytes { bytes in
                    var sent = 0
                    while sent < bytes.count {
                        let count = Darwin.write(
                            descriptor,
                            bytes.baseAddress!.advanced(by: sent),
                            bytes.count - sent
                        )
                        guard count > 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        sent += count
                    }
                }
                Darwin.shutdown(descriptor, SHUT_WR)
                var response = Data()
                var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
                while true {
                    let count = Darwin.read(
                        descriptor,
                        &buffer,
                        buffer.count
                    )
                    if count == 0 { break }
                    guard count > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    response.append(buffer, count: count)
                }
                return response
            }.value
        } catch {
            let elapsed = started.duration(to: .now)
            let translated: Error
            if let posixError = error as? POSIXError,
               posixError.code == .EAGAIN || posixError.code == .EWOULDBLOCK {
                translated = HubControlError.timedOut
            } else {
                translated = error
            }
            Self.logger.error(
                "control command failed: \(commandName, privacy: .public) after \(elapsed.formatted(), privacy: .public): \(String(describing: translated), privacy: .public)"
            )
            throw translated
        }
        let elapsed = started.duration(to: .now)
        Self.logger.debug(
            "control command finished: \(commandName, privacy: .public) in \(elapsed.formatted(), privacy: .public)"
        )
        guard !response.isEmpty else {
            Self.logger.error(
                "control command empty response: \(commandName, privacy: .public)"
            )
            throw HubControlError.emptyResponse
        }
        let envelope = try JSONSerialization.jsonObject(
            with: response
        ) as? [String: Any]
        guard let envelope,
              let isOK = envelope["ok"] as? Bool else {
            throw HubControlError.invalidResponse
        }
        guard isOK else {
            throw HubControlError.rejected(
                envelope["error"] as? String ?? "unknown error"
            )
        }
        guard let result = envelope["result"] else {
            throw HubControlError.invalidResponse
        }
        return result
    }
}
