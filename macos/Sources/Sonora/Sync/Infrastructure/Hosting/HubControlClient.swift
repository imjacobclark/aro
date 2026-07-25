import Darwin
import Foundation

struct HubPairingWindow: Sendable {
    let code: String
    let fingerprint: String
}

struct ControlledHubDevice: Identifiable, Codable, Sendable {
    let deviceID: UUID
    let name: String
    let revokedAt: Date?

    var id: UUID { deviceID }
}

struct HubControlClient: Sendable {
    let socketURL: URL

    func openPairing() async throws -> HubPairingWindow {
        let result = try await send(["command": "open_pairing"])
        guard let code = result["code"] as? String,
              let fingerprint = result["tls_fingerprint"] as? String else {
            throw CocoaError(.coderInvalidValue)
        }
        return HubPairingWindow(code: code, fingerprint: fingerprint)
    }

    func devices() async throws -> [ControlledHubDevice] {
        let result = try await sendValue(["command": "devices"])
        let data = try JSONSerialization.data(withJSONObject: result)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ControlledHubDevice].self, from: data)
    }

    func revoke(deviceID: UUID) async throws {
        _ = try await send([
            "command": "revoke",
            "device_id": deviceID.uuidString,
        ])
    }

    private func send(
        _ command: [String: Any]
    ) async throws -> [String: Any] {
        let result = try await sendValue(command)
        guard let object = result as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
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
        let envelope = try JSONSerialization.jsonObject(
            with: response
        ) as? [String: Any]
        guard let envelope,
              let isOK = envelope["ok"] as? Bool,
              isOK,
              let result = envelope["result"] else {
            throw CocoaError(.coderInvalidValue)
        }
        return result
    }
}
