import CryptoKit
import Foundation
import MatterController
import OSLog
import Security
import AroCommon

enum AroSyncClientError: LocalizedError {
    case invalidResponse
    case invalidPairingCode
    case pairingAuthenticationFailed
    case tlsFingerprintMismatch
    case incompatibleProtocol(
        library: String,
        available: ClosedRange<UInt16>
    )
    case httpError(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The hosting Aro returned an invalid response."
        case .invalidPairingCode:
            "Enter the six-digit pairing code shown by the hosting Aro."
        case .pairingAuthenticationFailed:
            "The pairing code could not authenticate this Aro."
        case .tlsFingerprintMismatch:
            "The certificate does not match the Aro saved during pairing."
        case .incompatibleProtocol(let library, let available):
            "\(library) is running an incompatible Aro server "
                + "(sync protocol \(available.lowerBound)–"
                + "\(available.upperBound)). This version requires protocol "
                + "\(AroSyncProtocol.currentVersion). Upgrade the hosting "
                + "Aro, then try again."
        case .httpError(let status, let message):
            "The hosting Aro returned HTTP \(status): \(message)"
        }
    }
}

enum HubPairingPollResult: Sendable {
    case pending
    case approved(CompletedHubPairing)
    case rejected
    case expired
}

struct RemoteTopologySnapshot: Codable, Sendable {
    let hubID: UUID
    let displayName: String
    let trackCount: UInt64?
    let devices: [ControlledHubDevice]
    let sources: [SourceHealthReport]
    let activeTransfers: UInt64
    let livePlayback: [RemoteTopologyPlayback]
}

struct RemoteTopologyPlayback: Codable, Sendable {
    let deviceID: UUID
    let deviceName: String
    let deviceType: String
    let state: PlaybackActivityState
    let observedAt: Date
    let playback: PlaybackActivitySnapshot
}

struct ManualMetadataUpload: Codable, Sendable {
    let contentHashes: [String]
    let fields: [String: JSONValue]
    let reset: Bool
}

struct ServerImportSession: Codable, Sendable {
    let importID: UUID
    let sourceID: UUID
}

struct ServerImportFileStatus: Codable, Sendable {
    let fileID: UUID
    let uploadedSize: UInt64
    let size: UInt64
}

struct HubPairingSession: Sendable {
    let requestID: UUID
    let deviceID: UUID
    let resultKey: Data
}

struct CompletedHubPairing: Sendable {
    let credential: HubDeviceCredential
    let tlsFingerprint: String
}

final class PairingTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // Pairing payloads are authenticated by SPAKE2+. The certificate pin
        // is delivered inside that encrypted exchange and used thereafter.
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

final class PinnedTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let fingerprint: String

    init(fingerprint: String) {
        self.fingerprint = fingerprint.lowercased()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustCopyCertificateChain(trust)
                .flatMap({ $0 as? [SecCertificate] })?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let data = SecCertificateCopyData(certificate) as Data
        let actual = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        guard actual == fingerprint else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

actor AroSyncClient {
    private static let logger = Logger(
        subsystem: "com.othyn.aro",
        category: "SyncClient"
    )

    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let adminToken: String?

    init(baseURL: URL, pinnedTLSFingerprint: String) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(
            configuration: configuration,
            delegate: PinnedTLSDelegate(
                fingerprint: pinnedTLSFingerprint
            ),
            delegateQueue: nil
        )
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder.aroSyncProtocol()
        adminToken = nil
    }

    init(pairingBaseURL baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(
            configuration: configuration,
            delegate: PairingTLSDelegate(),
            delegateQueue: nil
        )
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder.aroSyncProtocol()
        adminToken = nil
    }

    /// Pinned like the main initializer, but with a deliberately short timeout: this
    /// is used by `HubEndpointResolver` to probe candidate addresses, several of which
    /// are expected to be dead. A black-holed address must cost a couple of seconds,
    /// not the 15s a real request is allowed, or probing would be slower than the
    /// timeout it exists to avoid.
    init(probeBaseURL baseURL: URL, pinnedTLSFingerprint: String) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        session = URLSession(
            configuration: configuration,
            delegate: PinnedTLSDelegate(fingerprint: pinnedTLSFingerprint),
            delegateQueue: nil
        )
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder.aroSyncProtocol()
        adminToken = nil
    }

    init(discoveryBaseURL baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        session = URLSession(
            configuration: configuration,
            delegate: PairingTLSDelegate(),
            delegateQueue: nil
        )
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder.aroSyncProtocol()
        adminToken = nil
    }

    init(
        localAdminBaseURL baseURL: URL,
        adminToken: String,
        pinnedTLSFingerprint: String? = nil
    ) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        if let pinnedTLSFingerprint {
            session = URLSession(
                configuration: configuration,
                delegate: PinnedTLSDelegate(
                    fingerprint: pinnedTLSFingerprint
                ),
                delegateQueue: nil
            )
        } else {
            session = URLSession(
                configuration: configuration,
                delegate: PairingTLSDelegate(),
                delegateQueue: nil
            )
        }
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder.aroSyncProtocol()
        self.adminToken = adminToken
    }

    func hubInfo() async throws -> AroHubInfo {
        try await get("v1/hub")
    }

    func compatibleHubInfo() async throws -> AroHubInfo {
        let info = try await hubInfo()
        let current = AroSyncProtocol.currentVersion
        guard info.protocolMin <= current, info.protocolMax >= current else {
            throw AroSyncClientError.incompatibleProtocol(
                library: info.displayName,
                available: info.protocolMin ... info.protocolMax
            )
        }
        return info
    }

    func startPairing(
        deviceID: UUID,
        deviceName: String,
        code: String
    ) async throws -> HubPairingSession {
        guard code.count == 6,
              code.allSatisfy(\.isNumber),
              let passcode = UInt32(code) else {
            throw AroSyncClientError.invalidPairingCode
        }
        let pase = PASESession(passcode: passcode)
        let (pbkdfRequest, pbkdfContext) = pase.createPBKDFParamRequest(
            initiatorSessionID: 1
        )
        let response: PairingStart = try await post(
            "v1/pairing/start",
            body: PairingRequest(
                deviceID: deviceID,
                deviceName: deviceName,
                deviceType: "Mac",
                pbkdfRequest: pbkdfRequest.base64EncodedString()
            )
        )
        guard let pbkdfResponse = Data(
            base64Encoded: response.pbkdfResponse
        ) else {
            throw AroSyncClientError.invalidResponse
        }
        let (pake1, pakeContext) = try pase.handlePBKDFParamResponse(
            pbkdfParamResponse: pbkdfResponse,
            context: pbkdfContext
        )
        let pake2Response: PairingPake1 = try await post(
            "v1/pairing/\(response.requestID.uuidString)/pake1",
            body: PairingPake1Request(
                pake1: pake1.base64EncodedString()
            )
        )
        guard let pake2 = Data(base64Encoded: pake2Response.pake2) else {
            throw AroSyncClientError.invalidResponse
        }
        var pake3 = Data()
        var resultKey = Data()
        do {
            let completion = try pase.handlePake2(
                pake2Data: pake2,
                context: pakeContext
            )
            pake3 = completion.pake3
            guard let decryptionKey = completion.session.decryptKey else {
                throw AroSyncClientError.pairingAuthenticationFailed
            }
            resultKey = decryptionKey.withUnsafeBytes { Data($0) }
        } catch {
            throw AroSyncClientError.pairingAuthenticationFailed
        }
        let _: PairingConfirm = try await post(
            "v1/pairing/\(response.requestID.uuidString)/confirm",
            body: PairingConfirmRequest(
                pake3: pake3.base64EncodedString()
            )
        )
        return HubPairingSession(
            requestID: response.requestID,
            deviceID: deviceID,
            resultKey: resultKey
        )
    }

    func pollPairing(
        pairing: HubPairingSession
    ) async throws -> HubPairingPollResult {
        let response: PairingStatus = try await get(
            "v1/pairing/\(pairing.requestID.uuidString)"
                + "?device_id=\(pairing.deviceID.uuidString)"
        )
        switch response.state {
        case .pending:
            return .pending
        case .approved:
            guard let encrypted = response.encryptedResult,
                  let nonceData = Data(base64Encoded: encrypted.nonce),
                  let combined = Data(base64Encoded: encrypted.ciphertext),
                  nonceData.count == 12,
                  combined.count >= 16 else {
                throw AroSyncClientError.invalidResponse
            }
            let ciphertext = combined.dropLast(16)
            let tag = combined.suffix(16)
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: ciphertext,
                tag: tag
            )
            let aad = Data(
                (
                    "aro-pairing-v2:"
                        + pairing.requestID.uuidString.lowercased()
                        + ":"
                        + pairing.deviceID.uuidString.lowercased()
                ).utf8
            )
            let plaintext: Data
            do {
                plaintext = try AES.GCM.open(
                    sealedBox,
                    using: SymmetricKey(data: pairing.resultKey),
                    authenticating: aad
                )
            } catch {
                throw AroSyncClientError.pairingAuthenticationFailed
            }
            let result = try decoder.decode(PairingResult.self, from: plaintext)
            guard result.tlsFingerprint.count == 64 else {
                throw AroSyncClientError.invalidResponse
            }
            return .approved(
                CompletedHubPairing(
                    credential: result.credential,
                    tlsFingerprint: result.tlsFingerprint
                )
            )
        case .rejected:
            return .rejected
        case .expired:
            return .expired
        }
    }

    func exchange(
        _ exchange: SyncExchangeRequest,
        credential: HubDeviceCredential? = nil
    ) async throws -> SyncExchangeResponse {
        try await postAuthenticated(
            "v1/exchange",
            body: exchange,
            credential: credential
        )
    }

    func deviceAccess(
        credential: HubDeviceCredential
    ) async throws -> AroDeviceAccess {
        try await getAuthenticated("v1/device", credential: credential)
    }

    func exportManifest(
        credential: HubDeviceCredential? = nil
    ) async throws -> AroExportManifest {
        try await getAuthenticated(
            "v1/library/export-manifest",
            credential: credential
        )
    }

    func sourceHealth(
        credential: HubDeviceCredential? = nil
    ) async throws -> [SourceHealthReport] {
        try await getAuthenticated(
            "v1/library/sources",
            credential: credential
        )
    }

    func adminFolders() async throws -> [ControlledSourceFolder] {
        try await getAuthenticated("v1/admin/folders")
    }

    func adminDevices() async throws -> [ControlledHubDevice] {
        try await getAuthenticated("v1/devices")
    }

    func openAdminPairing() async throws -> HubPairingWindow {
        let response: AdminPairingWindowResponse = try await postAuthenticated(
            "v1/pairing/open",
            body: EmptyRequest(),
            credential: nil
        )
        return HubPairingWindow(
            code: response.code,
            expiresAt: Date().addingTimeInterval(
                TimeInterval(response.expiresInSeconds)
            )
        )
    }

    func pendingAdminPairingRequests() async throws -> [ControlledPairingRequest] {
        try await getAuthenticated("v1/pairing/requests")
    }

    func approveAdminPairing(
        requestID: UUID,
        approve: Bool,
        canContribute: Bool
    ) async throws {
        let _: HubDeviceCredential? = try await postAuthenticated(
            "v1/pairing/approve",
            body: AdminPairingApprovalRequest(
                requestID: requestID,
                approve: approve,
                canContribute: canContribute
            ),
            credential: nil
        )
    }

    func revokeAdminDevice(deviceID: UUID) async throws {
        try await postAuthenticatedNoContent(
            "v1/devices/revoke",
            body: AdminDeviceIDRequest(deviceID: deviceID),
            credential: nil
        )
    }

    func setAdminContribution(deviceID: UUID, allowed: Bool) async throws {
        try await postAuthenticatedNoContent(
            "v1/devices/permissions",
            body: AdminDevicePermissionRequest(
                deviceID: deviceID,
                canContribute: allowed
            ),
            credential: nil
        )
    }

    func addAdminFolder(path: String) async throws -> ControlledSourceFolder {
        try await postAuthenticated(
            "v1/admin/folders",
            body: AdminFolderPathRequest(path: path),
            credential: nil
        )
    }

    @discardableResult
    func scanAdminFolder(sourceID: UUID? = nil) async throws -> Int {
        let response: AdminFolderScanResponse = try await postAuthenticated(
            "v1/admin/folders/scan",
            body: AdminFolderScanRequest(sourceID: sourceID),
            credential: nil
        )
        return response.changedSongs
    }

    func relocateAdminFolder(
        sourceID: UUID,
        path: String
    ) async throws -> ControlledSourceFolder {
        try await postAuthenticated(
            "v1/admin/folders/relocate",
            body: RelocateAdminFolderRequest(
                sourceID: sourceID,
                path: path
            ),
            credential: nil
        )
    }

    func removeAdminFolder(sourceID: UUID) async throws {
        try await postAuthenticatedNoContent(
            "v1/admin/folders/remove",
            body: AdminFolderIDRequest(sourceID: sourceID),
            credential: nil
        )
    }

    func removeTrack(
        contentHash: String,
        credential: HubDeviceCredential? = nil
    ) async throws -> Bool {
        let response: RemoveServerTrackResponse = try await postAuthenticated(
            "v1/library/tracks/remove",
            body: RemoveServerTrackRequest(contentHash: contentHash),
            credential: credential
        )
        return response.removed
    }

    func createImport(
        sourceName: String,
        credential: HubDeviceCredential
    ) async throws -> ServerImportSession {
        try await postAuthenticated(
            "v1/imports",
            body: CreateServerImportRequest(sourceName: sourceName),
            credential: credential
        )
    }

    func uploadImportFile(
        importID: UUID,
        fileID: UUID,
        fileURL: URL,
        relativePath: String,
        credential: HubDeviceCredential
    ) async throws {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        guard let number = attributes[.size] as? NSNumber else {
            throw AroSyncClientError.invalidResponse
        }
        let size = number.uint64Value
        let registration = RegisterServerImportFileRequest(
            fileID: fileID,
            relativePath: relativePath,
            size: size
        )
        var status: ServerImportFileStatus = try await postAuthenticated(
            "v1/imports/\(importID.uuidString)/files",
            body: registration,
            credential: credential
        )
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: status.uploadedSize)
        var consecutiveFailures = 0
        while status.uploadedSize < size {
            let offset = status.uploadedSize
            let remaining = min(UInt64(1_048_576), size - status.uploadedSize)
            guard let chunk = try handle.read(upToCount: Int(remaining)),
                  !chunk.isEmpty else {
                throw AroSyncClientError.invalidResponse
            }
            do {
                status = try await logged(
                    "PUT",
                    "v1/imports/\(importID.uuidString)/files/\(fileID.uuidString)"
                ) {
                    var request = URLRequest(
                        url: try url(
                            for: "v1/imports/\(importID.uuidString)/files/\(fileID.uuidString)"
                        )
                    )
                    request.httpMethod = "PUT"
                    request.setValue(
                        String(offset),
                        forHTTPHeaderField: "X-Aro-Offset"
                    )
                    authenticate(&request, credential: credential)
                    request.httpBody = chunk
                    let (data, response) = try await session.data(for: request)
                    try validate(response, data: data)
                    return try decoder.decode(ServerImportFileStatus.self, from: data)
                }
                consecutiveFailures = 0
            } catch {
                // A response can be lost after the server persisted the chunk.
                // Re-registering is idempotent and returns the authoritative
                // offset, so the next loop resumes without duplicating bytes.
                consecutiveFailures += 1
                guard consecutiveFailures < 3 else { throw error }
                status = try await postAuthenticated(
                    "v1/imports/\(importID.uuidString)/files",
                    body: registration,
                    credential: credential
                )
                try handle.seek(toOffset: status.uploadedSize)
            }
        }
    }

    func commitImport(
        importID: UUID,
        credential: HubDeviceCredential
    ) async throws -> RemoteSyncJob {
        try await postAuthenticated(
            "v1/imports/\(importID.uuidString)/commit",
            body: EmptyRequest(),
            credential: credential
        )
    }

    func jobStatus(
        jobID: UUID,
        credential: HubDeviceCredential
    ) async throws -> RemoteSyncJob {
        try await getAuthenticated(
            "v1/jobs/\(jobID.uuidString)",
            credential: credential
        )
    }

    /// Server-owned, paginated catalog read. Streaming clients should use this
    /// instead of applying the complete CRDT replica merely to browse tracks.
    func catalog(
        cursor: UInt64 = 0,
        limit: UInt32 = 50,
        query: String? = nil,
        sort: String = "title",
        credential: HubDeviceCredential? = nil
    ) async throws -> CatalogPage {
        var path = "v1/library/catalog?cursor=\(cursor)&limit=\(limit)&sort=\(sort)"
        if let query, let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&q=\(encoded)"
        }
        return try await getAuthenticated(path, credential: credential)
    }

    /// Reads the complete lightweight catalog, following the server cursor until
    /// no further page remains. The hub deliberately caps an individual response
    /// at 200 tracks, so callers must not treat the first page as the library.
    func completeCatalog(
        pageSize: UInt32 = 200,
        query: String? = nil,
        sort: String = "title",
        credential: HubDeviceCredential? = nil
    ) async throws -> CatalogPage {
        var cursor: UInt64 = 0
        var tracks: [CatalogTrack] = []
        var seenTrackIDs: Set<UUID> = []
        var seenCursors: Set<UInt64> = [cursor]
        var revision: UInt64 = 0

        while true {
            let page = try await catalog(
                cursor: cursor,
                limit: pageSize,
                query: query,
                sort: sort,
                credential: credential
            )
            revision = page.revision
            for track in page.tracks where seenTrackIDs.insert(track.trackID).inserted {
                tracks.append(track)
            }

            guard let rawCursor = page.nextCursor,
                  let nextCursor = UInt64(rawCursor),
                  nextCursor > cursor,
                  seenCursors.insert(nextCursor).inserted else {
                return CatalogPage(
                    tracks: tracks,
                    nextCursor: nil,
                    revision: revision
                )
            }
            cursor = nextCursor
        }
    }

    /// Checks the first lightweight page's server revision before walking the
    /// remaining pages. A polling streaming client therefore pays one bounded
    /// request while the catalogue is unchanged instead of redownloading the
    /// complete library every thirty seconds.
    func completeCatalogIfChanged(
        from knownRevision: UInt64?,
        pageSize: UInt32 = 200,
        credential: HubDeviceCredential? = nil
    ) async throws -> CatalogPage? {
        let first = try await catalog(
            cursor: 0,
            limit: pageSize,
            credential: credential
        )
        if knownRevision == first.revision {
            return nil
        }
        var tracks = first.tracks
        var seenTrackIDs = Set(first.tracks.map(\.trackID))
        var cursor = first.nextCursor.flatMap(UInt64.init)
        var seenCursors: Set<UInt64> = [0]
        while let current = cursor,
              current > 0,
              seenCursors.insert(current).inserted {
            let page = try await catalog(
                cursor: current,
                limit: pageSize,
                credential: credential
            )
            for track in page.tracks where seenTrackIDs.insert(track.trackID).inserted {
                tracks.append(track)
            }
            cursor = page.nextCursor.flatMap(UInt64.init)
        }
        return CatalogPage(
            tracks: tracks,
            nextCursor: nil,
            revision: first.revision
        )
    }

    func libraryStats(
        credential: HubDeviceCredential? = nil
    ) async throws -> StatsDashboard {
        try await getAuthenticated("v1/library/stats", credential: credential)
    }

    func topology(
        credential: HubDeviceCredential? = nil
    ) async throws -> RemoteTopologySnapshot {
        try await getAuthenticated("v1/topology", credential: credential)
    }

    func setManualMetadata(
        _ request: ManualMetadataUpload,
        credential: HubDeviceCredential? = nil
    ) async throws {
        let _: [String: UInt64] = try await postAuthenticated(
            "v1/metadata-overrides",
            body: request,
            credential: credential
        )
    }

    /// Triggers (re-)identification on a *remote* hub for the given content hashes —
    /// the network equivalent of `HubControlClient.identifyTracks(_:)`, which only
    /// reaches a *local* `aro-server` over its Unix control socket. Deliberately takes
    /// content hashes only, not file paths: a path on this Mac's filesystem is
    /// meaningless to a remote server, which resolves its own on-disk path from the
    /// hash instead (see `aro-server`'s `POST /v1/identify` handler doc comment).
    /// Returns the number of hashes the hub could actually resolve to a live file and
    /// queue; a hash the hub doesn't recognize or whose file is currently unavailable
    /// is silently skipped rather than failing the whole batch.
    func identifyTracks(
        contentHashes: [String],
        credential: HubDeviceCredential? = nil
    ) async throws -> Int {
        let response: AroIdentifyTracksResponse = try await postAuthenticated(
            "v1/identify",
            body: AroIdentifyTracksRequest(contentHashes: contentHashes),
            credential: credential
        )
        return response.queued
    }

    /// Remote equivalent of `HubControlClient.identificationStatus()` — lets a pure
    /// remote client's Metadata page show live queue counts.
    func identificationStatus(
        credential: HubDeviceCredential? = nil
    ) async throws -> IdentificationStatus {
        try await getAuthenticated(
            "v1/identification/status",
            credential: credential
        )
    }

    /// Remote equivalent of `HubControlClient.identificationResults(after:)`.
    /// Identification results are keyed by content hash and deliberately live outside
    /// the CRDT operation log, so they never arrive through `exchange` the way track
    /// metadata does — without this a remote client could never receive them, leaving
    /// tracks with no *embedded* cover stuck on the placeholder artwork even though
    /// the hub had already fetched and cached one for them.
    ///
    /// `after` is the `identifiedAt` of the last result already merged (0 fetches
    /// everything), and results come back oldest-first so that cursor can simply
    /// advance to the last element's `identifiedAt`.
    func identificationResults(
        after: Int64,
        credential: HubDeviceCredential? = nil
    ) async throws -> [IdentificationResult] {
        try await getAuthenticated(
            "v1/identification/results?after=\(after)",
            credential: credential
        )
    }

    /// Reorders `contentHashes` so consecutive tracks sound alike (see `aro-server`'s
    /// `playlists::smart_shuffle`). POST rather than GET because a queue can run to
    /// hundreds of hashes.
    func smartShuffle(
        contentHashes: [String],
        start: String?,
        credential: HubDeviceCredential? = nil
    ) async throws -> [String] {
        try await postAuthenticated(
            "v1/shuffle",
            body: SmartShuffleRequest(contentHashes: contentHashes, start: start),
            credential: credential
        )
    }

    /// Remote equivalent of `HubControlClient.playlists()` — the hub's auto-generated
    /// playlists, keyed by content hash, for a pure remote client's Home screen.
    /// `utcOffsetMinutes` scopes Morning Rotation/Late Night to this device's timezone.
    func playlists(
        credential: HubDeviceCredential? = nil,
        utcOffsetMinutes: Int = TimeZone.current.secondsFromGMT() / 60
    ) async throws -> [ServerGeneratedPlaylist] {
        try await getAuthenticated(
            "v1/playlists?utc_offset_minutes=\(utcOffsetMinutes)",
            credential: credential
        )
    }

    /// Remote equivalent of `HubControlClient.radio(contentHash:)` — Tier 3
    /// "seed-track radio" for a pure remote client.
    func radio(
        contentHash: String,
        limit: Int = 30,
        credential: HubDeviceCredential? = nil
    ) async throws -> ServerGeneratedPlaylist? {
        try await getAuthenticated(
            "v1/radio/\(contentHash)?limit=\(limit)",
            credential: credential
        )
    }

    func reportPlaybackActivity(
        _ snapshot: PlaybackActivitySnapshot,
        credential: HubDeviceCredential?
    ) async throws {
        try await logged("POST", "v1/playback/activity") {
            var request = URLRequest(url: try url(for: "v1/playback/activity"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            authenticate(&request, credential: credential)
            request.httpBody = try encoder.encode(snapshot)
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data)
        }
    }

    func downloadBlob(
        hash: String,
        from offset: UInt64,
        credential: HubDeviceCredential? = nil
    ) async throws -> Data {
        try await logged("GET", "v1/blobs/\(hash)") {
            var request = URLRequest(url: try url(for: "v1/blobs/\(hash)"))
            request.httpMethod = "GET"
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            authenticate(&request, credential: credential)
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data)
            return data
        }
    }

    func uploadBlob(
        fileURL: URL,
        expectedHash: String,
        expectedSize: UInt64,
        credential: HubDeviceCredential
    ) async throws {
        let status: AroBlobStatus = try await getAuthenticated(
            "v1/blobs/\(expectedHash)/status",
            credential: credential
        )
        if status.exists {
            guard status.committedSize == expectedSize else {
                throw AroSyncClientError.invalidResponse
            }
            return
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: status.uploadedSize)
        var offset = status.uploadedSize
        while offset < expectedSize {
            let remaining = min(UInt64(1_048_576), expectedSize - offset)
            guard let chunk = try handle.read(upToCount: Int(remaining)),
                  !chunk.isEmpty else {
                throw AroSyncClientError.invalidResponse
            }
            try await logged("PUT", "v1/blobs/\(expectedHash)") {
                var request = URLRequest(
                    url: try url(for: "v1/blobs/\(expectedHash)")
                )
                request.httpMethod = "PUT"
                request.setValue(
                    "application/octet-stream",
                    forHTTPHeaderField: "Content-Type"
                )
                request.setValue("identity", forHTTPHeaderField: "Content-Encoding")
                request.setValue(String(offset), forHTTPHeaderField: "X-Aro-Offset")
                authenticate(&request, credential: credential)
                let (data, response) = try await session.upload(
                    for: request,
                    from: chunk
                )
                try validate(response, data: data)
            }
            offset += UInt64(chunk.count)
        }
        let _: AroBlobStatus = try await postAuthenticated(
            "v1/blobs/commit",
            body: AroBlobCommitRequest(
                hash: expectedHash,
                size: expectedSize
            ),
            credential: credential
        )
    }

    func previewJoin(
        _ request: JoinPreviewRequest,
        credential: HubDeviceCredential
    ) async throws -> FirstJoinPreview {
        try await postAuthenticated(
            "v1/join/preview",
            body: request,
            credential: credential
        )
    }

    func commitJoin(
        _ request: JoinCommitRequest,
        credential: HubDeviceCredential
    ) async throws -> RemoteSyncJob {
        try await postAuthenticated(
            "v1/join/commit",
            body: request,
            credential: credential
        )
    }

    private func get<Response: Decodable>(
        _ path: String
    ) async throws -> Response {
        try await logged("GET", path) {
            let (data, response) = try await session.data(
                from: try url(for: path)
            )
            try validate(response, data: data)
            return try decoder.decode(Response.self, from: data)
        }
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        try await logged("POST", path) {
            var request = URLRequest(url: try url(for: path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data)
            return try decoder.decode(Response.self, from: data)
        }
    }

    private func postAuthenticated<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        credential: HubDeviceCredential?
    ) async throws -> Response {
        try await logged("POST", path) {
            var request = URLRequest(url: try url(for: path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            authenticate(&request, credential: credential)
            request.httpBody = try encoder.encode(body)
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data)
            return try decoder.decode(Response.self, from: data)
        }
    }

    private func getAuthenticated<Response: Decodable>(
        _ path: String,
        credential: HubDeviceCredential? = nil
    ) async throws -> Response {
        try await logged("GET", path) {
            var request = URLRequest(url: try url(for: path))
            request.httpMethod = "GET"
            authenticate(&request, credential: credential)
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data)
            return try decoder.decode(Response.self, from: data)
        }
    }

    private func postAuthenticatedNoContent<Body: Encodable>(
        _ path: String,
        body: Body,
        credential: HubDeviceCredential?
    ) async throws {
        try await logged("POST", path) {
            var request = URLRequest(url: try url(for: path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            authenticate(&request, credential: credential)
            request.httpBody = try encoder.encode(body)
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data)
        }
    }

    /// Wraps every request this client makes with start/duration/failure logging —
    /// before this, a failed or hung request (TLS pinning rejection, timeout, 5xx)
    /// was completely invisible: every call site above either propagated the error
    /// silently up to a `try?` at the UI layer, or was never logged at all, which is
    /// why prior debugging of "requests are timing out" via `log show` found zero
    /// entries for this subsystem.
    private func logged<T>(
        _ method: String,
        _ path: String,
        _ operation: () async throws -> T
    ) async throws -> T {
        let started = ContinuousClock.now
        do {
            let result = try await operation()
            Self.logger.debug(
                "\(method, privacy: .public) \(path, privacy: .public) succeeded in \(started.duration(to: .now).formatted(), privacy: .public)"
            )
            return result
        } catch {
            Self.logger.error(
                "\(method, privacy: .public) \(path, privacy: .public) failed after \(started.duration(to: .now).formatted(), privacy: .public): \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    private func authenticate(
        _ request: inout URLRequest,
        credential: HubDeviceCredential?
    ) {
        if let credential {
            request.setValue(
                "Bearer \(credential.credential)",
                forHTTPHeaderField: "Authorization"
            )
            request.setValue(
                credential.deviceID.uuidString,
                forHTTPHeaderField: "X-Aro-Device"
            )
        } else if let adminToken {
            request.setValue(
                "Bearer \(adminToken)",
                forHTTPHeaderField: "Authorization"
            )
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AroSyncClientError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(
                HubErrorResponse.self,
                from: data
            ).message) ?? HTTPURLResponse.localizedString(
                forStatusCode: http.statusCode
            )
            throw AroSyncClientError.httpError(
                status: http.statusCode,
                message: message
            )
        }
    }

    private func url(for path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw AroSyncClientError.invalidResponse
        }
        return url
    }
}

private struct AdminFolderPathRequest: Encodable {
    let path: String
}

private struct EmptyRequest: Encodable {}

private struct AdminPairingWindowResponse: Decodable {
    let code: String
    let expiresInSeconds: Int
}

private struct AdminPairingApprovalRequest: Encodable {
    let requestID: UUID
    let approve: Bool
    let canContribute: Bool
}

private struct AdminDeviceIDRequest: Encodable {
    let deviceID: UUID
}

private struct AdminDevicePermissionRequest: Encodable {
    let deviceID: UUID
    let canContribute: Bool
}

private struct AdminFolderIDRequest: Encodable {
    let sourceID: UUID
}

private struct RelocateAdminFolderRequest: Encodable {
    let sourceID: UUID
    let path: String
}

private struct RemoveServerTrackRequest: Encodable {
    let contentHash: String
}

private struct RemoveServerTrackResponse: Decodable {
    let removed: Bool
}

private struct CreateServerImportRequest: Encodable {
    let sourceName: String
}

private struct RegisterServerImportFileRequest: Encodable {
    let fileID: UUID
    let relativePath: String
    let size: UInt64
}

private struct PairingRequest: Encodable {
    let deviceID: UUID
    let deviceName: String
    let deviceType: String
    let pbkdfRequest: String
}

private struct PairingStart: Decodable {
    let requestID: UUID
    let pbkdfResponse: String
}

private struct PairingPake1Request: Encodable {
    let pake1: String
}

private struct PairingPake1: Decodable {
    let pake2: String
}

private struct PairingConfirmRequest: Encodable {
    let pake3: String
}

private struct PairingConfirm: Decodable {
    let state: HubPairingState
}

private struct PairingStatus: Decodable {
    let state: HubPairingState
    let encryptedResult: EncryptedPairingResult?
}

private struct EncryptedPairingResult: Decodable {
    let nonce: String
    let ciphertext: String
}

private struct PairingResult: Decodable {
    let credential: HubDeviceCredential
    let tlsFingerprint: String
}

private enum HubPairingState: String, Decodable {
    case pending
    case approved
    case rejected
    case expired
}

private struct AroSyncCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension JSONDecoder {
    static func aroSyncProtocol() -> JSONDecoder {
        let decoder = JSONDecoder()
        // Rust's chrono serializer emits RFC 3339 strings, including
        // fractional seconds such as `2026-07-27T08:58:08.570370131Z`.
        // JSONDecoder otherwise expects Date's numeric reference-date format.
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .custom { codingPath in
            let source = codingPath.last?.stringValue ?? ""
            if source == "physical_millis" {
                return AroSyncCodingKey(stringValue: "physicalMillis")!
            }
            let components = source.split(separator: "_")
            guard components.count > 1 else {
                return AroSyncCodingKey(stringValue: source)!
            }
            let converted = components.enumerated().map { index, component in
                let value = String(component)
                guard index > 0 else { return value }
                switch value {
                case "id":
                    return "ID"
                case "url":
                    return "URL"
                default:
                    return value.prefix(1).uppercased() + value.dropFirst()
                }
            }.joined()
            return AroSyncCodingKey(stringValue: converted)!
        }
        return decoder
    }
}

private struct SmartShuffleRequest: Encodable {
    let contentHashes: [String]
    let start: String?
}

private struct AdminFolderScanRequest: Encodable {
    let sourceID: UUID?
}

private struct AdminFolderScanResponse: Decodable {
    let changedSongs: Int
}

private struct HubErrorResponse: Decodable {
    let message: String
}
