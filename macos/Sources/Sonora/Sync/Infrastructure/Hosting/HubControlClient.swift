import Darwin
import Foundation
import SonoraCommon

enum HubControlError: LocalizedError {
    case emptyResponse
    case invalidResponse
    case rejected(String)
    case incompatibleHelper

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            "The Sonora Background Service closed its control connection without responding."
        case .invalidResponse:
            "The Sonora Background Service returned an invalid control response."
        case .rejected(let message):
            "The Sonora Background Service rejected the request: \(message)"
        case .incompatibleHelper:
            "The running Sonora Background Service is from an older app build."
        }
    }
}

struct HubPairingWindow: Sendable {
    let code: String
}

struct ControlledHubDevice: Identifiable, Codable, Sendable {
    let deviceID: UUID
    let name: String
    let revokedAt: Date?

    var id: UUID { deviceID }
}

struct ControlledPairingRequest: Identifiable, Codable, Sendable {
    let requestID: UUID
    let deviceID: UUID
    let deviceName: String
    let expiresAt: String

    var id: UUID { requestID }
}

struct HubControlClient: Sendable {
    static let controlProtocolVersion = 3

    let socketURL: URL

    func verifyCompatibility() async throws {
        let result = try await send(["command": "status"])
        guard let version = result["control_protocol_version"] as? Int,
              version == Self.controlProtocolVersion else {
            throw HubControlError.incompatibleHelper
        }
    }

    func openPairing() async throws -> HubPairingWindow {
        let result = try await send(["command": "open_pairing"])
        guard let code = result["code"] as? String else {
            throw HubControlError.invalidResponse
        }
        return HubPairingWindow(code: code)
    }

    func devices() async throws -> [ControlledHubDevice] {
        let result = try await sendValue(["command": "devices"])
        let data = try JSONSerialization.data(withJSONObject: result)
        let decoder = JSONDecoder.sonoraSyncProtocol()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ControlledHubDevice].self, from: data)
    }

    func pendingPairingRequests() async throws -> [ControlledPairingRequest] {
        let result = try await sendValue([
            "command": "pending_pairing_requests"
        ])
        let data = try JSONSerialization.data(withJSONObject: result)
        let decoder = JSONDecoder.sonoraSyncProtocol()
        return try decoder.decode([ControlledPairingRequest].self, from: data)
    }

    func approvePairing(requestID: UUID, approve: Bool) async throws {
        _ = try await sendValue([
            "command": "approve",
            "request_id": requestID.uuidString,
            "approve": approve,
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
