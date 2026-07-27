import Foundation
import Network
import Observation

struct HubEndpointCandidate: Identifiable, Hashable, Sendable {
    let hubID: UUID
    let name: String
    let host: String

    var id: UUID { hubID }

    var baseURL: URL? {
        URL(string: address)
    }

    var address: String { "https://\(host):4848" }
}

@MainActor
@Observable
final class AroHubBrowser {
    private var browser: NWBrowser?
    private var validationTask: Task<Void, Never>?
    private var scanID = UUID()
    var hubs: [HubEndpointCandidate] = []
    var errorMessage: String?
    var isSearching = false

    func restart() {
        stop()
        errorMessage = nil
        isSearching = true
        start()
    }

    func start() {
        guard browser == nil else { return }
        let scanID = UUID()
        self.scanID = scanID
        isSearching = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: "_aro-sync._tcp",
                domain: "local."
            ),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .failed(let error) = state {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let candidates = results.compactMap {
                result -> HubEndpointCandidate? in
                guard case .service(
                    let name,
                    _,
                    let domain,
                    _
                ) = result.endpoint else {
                    return nil
                }
                guard case .bonjour(let record) = result.metadata else {
                    return nil
                }
                return Self.candidate(
                    name: name,
                    domain: domain,
                    txt: record.dictionary
                )
            }
            Task { @MainActor in
                self?.validate(candidates, scanID: scanID)
            }
        }
        browser.start(queue: .global(qos: .utility))
        self.browser = browser
    }

    func stop() {
        validationTask?.cancel()
        validationTask = nil
        browser?.cancel()
        browser = nil
        hubs = []
        isSearching = false
        scanID = UUID()
    }

    nonisolated static func candidate(
        name: String,
        domain: String,
        txt: [String: String]
    ) -> HubEndpointCandidate? {
        guard let hubID = txt["hub_id"].flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        guard let host = txt["host"].flatMap({ value in
            value.isEmpty ? nil : value
        }) else {
            return nil
        }
        return HubEndpointCandidate(
            hubID: hubID,
            name: txt["name"] ?? name,
            host: host
        )
    }

    private func validate(
        _ candidates: [HubEndpointCandidate],
        scanID: UUID
    ) {
        validationTask?.cancel()
        isSearching = true
        validationTask = Task { [weak self] in
            var verified: [HubEndpointCandidate] = []
            await withTaskGroup(
                of: HubEndpointCandidate?.self
            ) { group in
                for candidate in Dictionary(
                    candidates.map { ($0.hubID, $0) },
                    uniquingKeysWith: { first, _ in first }
                ).values {
                    group.addTask {
                        guard let baseURL = candidate.baseURL else { return nil }
                        do {
                            let client = AroSyncClient(
                                discoveryBaseURL: baseURL
                            )
                            let info = try await client.hubInfo()
                            return info.hubID == candidate.hubID
                                ? candidate
                                : nil
                        } catch {
                            return nil
                        }
                    }
                }
                for await candidate in group {
                    if let candidate {
                        verified.append(candidate)
                    }
                }
            }
            guard !Task.isCancelled,
                  let self,
                  self.scanID == scanID else {
                return
            }
            self.hubs = verified.sorted {
                $0.name.localizedStandardCompare($1.name)
                    == .orderedAscending
            }
            self.errorMessage = verified.isEmpty && !candidates.isEmpty
                ? "Bonjour found a Aro, but its secure connection could "
                    + "not be reached. Check macOS Firewall settings on the "
                    + "hosting Mac."
                : nil
            self.isSearching = false
        }
    }
}
