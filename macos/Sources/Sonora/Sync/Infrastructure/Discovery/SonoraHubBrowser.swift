import Network
import Observation

struct HubEndpointCandidate: Identifiable, Hashable, Sendable {
    let name: String
    let host: String

    var id: String { "\(name)|\(host)" }
}

@MainActor
@Observable
final class SonoraHubBrowser {
    private var browser: NWBrowser?
    var hubs: [HubEndpointCandidate] = []
    var errorMessage: String?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjour(type: "_sonora-sync._tcp", domain: "local."),
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
            let candidates = results.compactMap { result -> HubEndpointCandidate? in
                guard case .service(
                    let name,
                    _,
                    let domain,
                    _
                ) = result.endpoint else {
                    return nil
                }
                return HubEndpointCandidate(
                    name: name,
                    host: "\(name).\(domain)"
                )
            }
            Task { @MainActor in
                self?.hubs = candidates.sorted {
                    $0.name.localizedStandardCompare($1.name)
                        == .orderedAscending
                }
            }
        }
        browser.start(queue: .global(qos: .utility))
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        hubs = []
    }
}
