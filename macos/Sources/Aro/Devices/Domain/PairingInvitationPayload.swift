import Foundation

struct PairingInvitationPayload: Equatable, Sendable {
    let hubID: UUID
    let address: URL
    let code: String
    let expiresAt: Date

    init?(url: URL, now: Date = .now) {
        guard url.scheme == "aro",
              url.host == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let version = components.value(named: "v"),
              version == "1",
              let hubIDText = components.value(named: "hub"),
              let hubID = UUID(uuidString: hubIDText),
              let addressText = components.value(named: "address"),
              let address = URL(string: addressText),
              address.scheme == "https",
              let code = components.value(named: "code"),
              code.count == 6,
              code.allSatisfy(\.isNumber),
              let expiryText = components.value(named: "expires"),
              let expiry = TimeInterval(expiryText) else {
            return nil
        }
        let expiresAt = Date(timeIntervalSince1970: expiry)
        guard expiresAt > now else { return nil }
        self.hubID = hubID
        self.address = address
        self.code = code
        self.expiresAt = expiresAt
    }
}

private extension URLComponents {
    func value(named name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}
