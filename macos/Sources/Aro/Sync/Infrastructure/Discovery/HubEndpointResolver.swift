import Darwin
import Foundation
import OSLog

/// Picks a base URL for a paired hub that can actually be *reached*, rather than
/// trusting the one recorded at pairing time.
///
/// Hubs are stored by their Bonjour hostname (`https://aro-<id>.local.:4848`), and
/// mDNS answers that name with every address the host has — including IPv6 addresses
/// that are advertised but unroutable between the two machines (observed directly:
/// four `2a00:`/`fe80:` records that black-hole, alongside one working IPv4). Because
/// they black-hole rather than refuse, a connection attempt that picks one burns the
/// client's entire request timeout instead of failing over, which surfaces as
/// "Library sync failed: The request timed out" at random.
///
/// Re-browsing Bonjour does not help on its own — it returns that same hostname with
/// the same bad records behind it. So this resolves the name down to concrete
/// addresses, probes them, and pins the winner.
///
/// Every candidate is verified end to end before being trusted: `/v1/hub` must answer
/// *and* report the expected `hubID`, over a TLS session pinned to the fingerprint
/// captured at pairing. `PinnedTLSDelegate` compares the certificate's SHA-256 rather
/// than validating hostnames, so swapping in an IP literal keeps exactly the same
/// security properties as the stored hostname — a spoofed host on either address
/// fails the pin and is discarded.
@MainActor
enum HubEndpointResolver {
    private static let logger = Logger(
        subsystem: "com.othyn.aro",
        category: "HubEndpoint"
    )

    /// Per-hub memory of the last endpoint that actually worked, so a library that
    /// needed an IP literal last time starts there instead of re-learning the same
    /// lesson (and re-paying a timeout) on every launch.
    /// Versioned so a change in selection strategy discards endpoints pinned by an
    /// older build — v1 could pin the ambiguous hostname, which defeats the point.
    private static func cacheKey(_ hubID: UUID) -> String {
        "sync.endpoint.lastGood.v2.\(hubID.uuidString)"
    }

    private static func cachedEndpoint(_ hubID: UUID) -> URL? {
        UserDefaults.standard.string(forKey: cacheKey(hubID)).flatMap(URL.init(string:))
    }

    private static func remember(_ url: URL, for hubID: UUID) {
        UserDefaults.standard.set(url.absoluteString, forKey: cacheKey(hubID))
    }

    /// Forgets the pinned endpoint for a hub, so the next resolve re-probes from
    /// scratch. Called when a request against the cached endpoint fails, since an
    /// address that worked on one network is meaningless on another.
    static func invalidate(hubID: UUID) {
        UserDefaults.standard.removeObject(forKey: cacheKey(hubID))
    }

    /// A reachable base URL for `hubID`, or `storedBaseURL` unchanged when nothing
    /// verifies — callers still attempt the request in that case, so a resolver that
    /// can't reach anything degrades to exactly today's behaviour rather than
    /// blocking sync outright.
    static func resolve(
        storedBaseURL: URL,
        hubID: UUID,
        tlsFingerprint: String
    ) async -> URL {
        for candidate in candidates(storedBaseURL: storedBaseURL, hubID: hubID) {
            if await verify(candidate, hubID: hubID, tlsFingerprint: tlsFingerprint) {
                remember(candidate, for: hubID)
                if candidate != storedBaseURL {
                    logger.info(
                        "resolved hub to reachable endpoint \(candidate.absoluteString, privacy: .public)"
                    )
                }
                return candidate
            }
            logger.debug(
                "endpoint unreachable: \(candidate.absoluteString, privacy: .public)"
            )
        }
        logger.error(
            "no reachable endpoint for hub; falling back to \(storedBaseURL.absoluteString, privacy: .public)"
        )
        return storedBaseURL
    }

    /// Ordered: whatever worked last time, then each concrete address behind the
    /// stored hostname, then the hostname itself as a last resort. Deduplicated so a
    /// cached endpoint that also appears in DNS isn't probed twice.
    ///
    /// Concrete addresses deliberately outrank the hostname even though the hostname
    /// often works. Verifying the hostname only proves that *this* connection
    /// happened to select a live address — the name still resolves to the dead ones,
    /// so a later request can pick one and stall. Pinning a specific verified address
    /// removes that ambiguity, which is the entire point of resolving at all.
    private static func candidates(storedBaseURL: URL, hubID: UUID) -> [URL] {
        var ordered: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL?) {
            guard let url, seen.insert(url.absoluteString).inserted else { return }
            ordered.append(url)
        }
        add(cachedEndpoint(hubID))
        if let host = storedBaseURL.host {
            let port = storedBaseURL.port ?? 4848
            for address in addresses(for: host) {
                // IPv6 literals must be bracketed in a URL authority.
                let authority = address.contains(":") ? "[\(address)]" : address
                add(URL(string: "https://\(authority):\(port)"))
            }
        }
        add(storedBaseURL)
        return ordered
    }

    /// Every A/AAAA record behind `host`, IPv4 first. IPv4 leads deliberately: in the
    /// failure this exists to fix it's the v6 records that are dead, and probing the
    /// most likely winner first keeps the common path to a single fast round trip.
    private static func addresses(for host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        // Bonjour names are published with a trailing dot; `getaddrinfo` handles it,
        // but trimming keeps the derived URLs tidy.
        let queryHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard getaddrinfo(queryHost, nil, &hints, &result) == 0, let head = result else {
            return []
        }
        defer { freeaddrinfo(result) }

        var v4: [String] = []
        var v6: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.pointee.ai_addr,
                info.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let address = String(cString: buffer)
                if !address.isEmpty {
                    // Link-local v6 carries a `%interface` scope that is meaningless
                    // in a URL, and those records were among the dead ones anyway.
                    if info.pointee.ai_family == AF_INET6 {
                        if !address.contains("%") { v6.append(address) }
                    } else {
                        v4.append(address)
                    }
                }
            }
            cursor = info.pointee.ai_next
        }
        return v4 + v6
    }

    /// A candidate counts as reachable only if it answers `/v1/hub` with the expected
    /// hub identity over a correctly-pinned TLS session. The client used here has its
    /// own short timeout (see `AroSyncClient.init(probeBaseURL:pinnedTLSFingerprint:)`)
    /// so probing a black-holed address costs a couple of seconds, not a full request
    /// timeout each.
    private static func verify(
        _ baseURL: URL,
        hubID: UUID,
        tlsFingerprint: String
    ) async -> Bool {
        let client = AroSyncClient(
            probeBaseURL: baseURL,
            pinnedTLSFingerprint: tlsFingerprint
        )
        guard let info = try? await client.hubInfo() else { return false }
        return info.hubID == hubID
    }
}
