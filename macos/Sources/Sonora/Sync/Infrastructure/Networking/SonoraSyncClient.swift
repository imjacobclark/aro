import CryptoKit
import Foundation
import MatterController
import Security
import SonoraCommon

enum SonoraSyncClientError: LocalizedError {
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
            "The hosting Sonora returned an invalid response."
        case .invalidPairingCode:
            "Enter the six-digit pairing code shown by the hosting Sonora."
        case .pairingAuthenticationFailed:
            "The pairing code could not authenticate this Sonora."
        case .tlsFingerprintMismatch:
            "The certificate does not match the Sonora saved during pairing."
        case .incompatibleProtocol(let library, let available):
            "\(library) is running an incompatible Sonora server "
                + "(sync protocol \(available.lowerBound)–"
                + "\(available.upperBound)). This version requires protocol "
                + "\(SonoraSyncProtocol.currentVersion). Upgrade the hosting "
                + "Sonora, then try again."
        case .httpError(let status, let message):
            "The hosting Sonora returned HTTP \(status): \(message)"
        }
    }
}

enum HubPairingPollResult: Sendable {
    case pending
    case approved(CompletedHubPairing)
    case rejected
    case expired
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

actor SonoraSyncClient {
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
        decoder = JSONDecoder.sonoraSyncProtocol()
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
        decoder = JSONDecoder.sonoraSyncProtocol()
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
        decoder = JSONDecoder.sonoraSyncProtocol()
        adminToken = nil
    }

    init(localAdminBaseURL baseURL: URL, adminToken: String) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        session = URLSession(
            configuration: configuration,
            delegate: PairingTLSDelegate(),
            delegateQueue: nil
        )
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        decoder = JSONDecoder.sonoraSyncProtocol()
        self.adminToken = adminToken
    }

    func hubInfo() async throws -> SonoraHubInfo {
        try await get("v1/hub")
    }

    func compatibleHubInfo() async throws -> SonoraHubInfo {
        let info = try await hubInfo()
        let current = SonoraSyncProtocol.currentVersion
        guard info.protocolMin <= current, info.protocolMax >= current else {
            throw SonoraSyncClientError.incompatibleProtocol(
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
            throw SonoraSyncClientError.invalidPairingCode
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
            throw SonoraSyncClientError.invalidResponse
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
            throw SonoraSyncClientError.invalidResponse
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
                throw SonoraSyncClientError.pairingAuthenticationFailed
            }
            resultKey = decryptionKey.withUnsafeBytes { Data($0) }
        } catch {
            throw SonoraSyncClientError.pairingAuthenticationFailed
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
                throw SonoraSyncClientError.invalidResponse
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
                    "sonora-pairing-v2:"
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
                throw SonoraSyncClientError.pairingAuthenticationFailed
            }
            let result = try decoder.decode(PairingResult.self, from: plaintext)
            guard result.tlsFingerprint.count == 64 else {
                throw SonoraSyncClientError.invalidResponse
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
        credential: HubDeviceCredential
    ) async throws -> SyncExchangeResponse {
        try await postAuthenticated(
            "v1/exchange",
            body: exchange,
            credential: credential
        )
    }

    func deviceAccess(
        credential: HubDeviceCredential
    ) async throws -> SonoraDeviceAccess {
        try await getAuthenticated("v1/device", credential: credential)
    }

    func exportManifest(
        credential: HubDeviceCredential? = nil
    ) async throws -> SonoraExportManifest {
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

    func downloadBlob(
        hash: String,
        from offset: UInt64,
        credential: HubDeviceCredential? = nil
    ) async throws -> Data {
        var request = URLRequest(url: try url(for: "v1/blobs/\(hash)"))
        request.httpMethod = "GET"
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        authenticate(&request, credential: credential)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return data
    }

    func uploadBlob(
        fileURL: URL,
        expectedHash: String,
        expectedSize: UInt64,
        credential: HubDeviceCredential
    ) async throws {
        let status: SonoraBlobStatus = try await getAuthenticated(
            "v1/blobs/\(expectedHash)/status",
            credential: credential
        )
        if status.exists {
            guard status.committedSize == expectedSize else {
                throw SonoraSyncClientError.invalidResponse
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
                throw SonoraSyncClientError.invalidResponse
            }
            var request = URLRequest(
                url: try url(for: "v1/blobs/\(expectedHash)")
            )
            request.httpMethod = "PUT"
            request.setValue(
                "application/octet-stream",
                forHTTPHeaderField: "Content-Type"
            )
            request.setValue("identity", forHTTPHeaderField: "Content-Encoding")
            request.setValue(String(offset), forHTTPHeaderField: "X-Sonora-Offset")
            authenticate(&request, credential: credential)
            let (data, response) = try await session.upload(
                for: request,
                from: chunk
            )
            try validate(response, data: data)
            offset += UInt64(chunk.count)
        }
        let _: SonoraBlobStatus = try await postAuthenticated(
            "v1/blobs/commit",
            body: SonoraBlobCommitRequest(
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
        let (data, response) = try await session.data(
            from: try url(for: path)
        )
        try validate(response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func postAuthenticated<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        credential: HubDeviceCredential
    ) async throws -> Response {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(credential.credential)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            credential.deviceID.uuidString,
            forHTTPHeaderField: "X-Sonora-Device"
        )
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func getAuthenticated<Response: Decodable>(
        _ path: String,
        credential: HubDeviceCredential? = nil
    ) async throws -> Response {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = "GET"
        authenticate(&request, credential: credential)
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try decoder.decode(Response.self, from: data)
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
                forHTTPHeaderField: "X-Sonora-Device"
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
            throw SonoraSyncClientError.invalidResponse
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(
                HubErrorResponse.self,
                from: data
            ).message) ?? HTTPURLResponse.localizedString(
                forStatusCode: http.statusCode
            )
            throw SonoraSyncClientError.httpError(
                status: http.statusCode,
                message: message
            )
        }
    }

    private func url(for path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw SonoraSyncClientError.invalidResponse
        }
        return url
    }
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

private struct SonoraSyncCodingKey: CodingKey {
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
    static func sonoraSyncProtocol() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { codingPath in
            let source = codingPath.last?.stringValue ?? ""
            if source == "physical_millis" {
                return SonoraSyncCodingKey(stringValue: "physicalMillis")!
            }
            let components = source.split(separator: "_")
            guard components.count > 1 else {
                return SonoraSyncCodingKey(stringValue: source)!
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
            return SonoraSyncCodingKey(stringValue: converted)!
        }
        return decoder
    }
}

private struct HubErrorResponse: Decodable {
    let message: String
}
