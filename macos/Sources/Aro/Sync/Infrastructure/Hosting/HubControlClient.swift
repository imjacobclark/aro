import Darwin
import Foundation
import AroCommon

enum HubControlError: LocalizedError {
    case emptyResponse
    case invalidResponse
    case rejected(String)
    case incompatibleHelper

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
}

struct HubControlClient: Sendable {
    static let controlProtocolVersion = 6

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
              let pairingAvailable = result["pairing_available"] as? Bool else {
            throw HubControlError.invalidResponse
        }
        return HubControlStatus(
            hubID: hubID,
            displayName: displayName,
            pairingAvailable: pairingAvailable
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
        let request = try JSONSerialization.data(withJSONObject: command)
        let response = try await Task.detached {
            let descriptor = socket(
                AF_UNIX,
                SOCK_STREAM,
                0
            )
            guard descriptor >= 0 else {
                throw POSIXError(.ENOTCONN)
            }
            defer { Darwin.close(descriptor) }

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
                        throw POSIXError(.EIO)
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
                guard count > 0 else { throw POSIXError(.EIO) }
                response.append(buffer, count: count)
            }
            return response
        }.value
        guard !response.isEmpty else {
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
