import CryptoKit
import Foundation
import Security
import SonoraCommon

enum SonoraSyncClientError: LocalizedError {
    case invalidResponse
    case tlsFingerprintMismatch
    case httpError(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The Sonora hub returned an invalid response."
        case .tlsFingerprintMismatch:
            "The hub certificate does not match the pairing fingerprint."
        case .httpError(let status, let message):
            "The Sonora hub returned HTTP \(status): \(message)"
        }
    }
}

enum HubPairingPollResult: Sendable {
    case pending
    case approved(HubDeviceCredential)
    case rejected
    case expired
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
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func hubInfo() async throws -> SonoraHubInfo {
        try await get("v1/hub")
    }

    func startPairing(
        deviceID: UUID,
        deviceName: String,
        code: String,
        fingerprint: String
    ) async throws -> UUID {
        let response: PairingStart = try await post(
            "v1/pairing/start",
            body: PairingRequest(
                deviceID: deviceID,
                deviceName: deviceName,
                code: code,
                pinnedTLSFingerprint: fingerprint
            )
        )
        return response.requestID
    }

    func pollPairing(
        requestID: UUID,
        deviceID: UUID
    ) async throws -> HubPairingPollResult {
        let response: PairingStatus = try await get(
            "v1/pairing/\(requestID.uuidString)?device_id=\(deviceID.uuidString)"
        )
        switch response.state {
        case .pending:
            return .pending
        case .approved:
            guard let credential = response.credential else {
                throw SonoraSyncClientError.invalidResponse
            }
            return .approved(credential)
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
    let code: String
    let pinnedTLSFingerprint: String
}

private struct PairingStart: Decodable {
    let requestID: UUID
}

private struct PairingStatus: Decodable {
    let state: HubPairingState
    let credential: HubDeviceCredential?
}

private enum HubPairingState: String, Decodable {
    case pending
    case approved
    case rejected
    case expired
}

private struct HubErrorResponse: Decodable {
    let message: String
}
