import Foundation
import AroCommon
import SwiftUI

struct ConnectLibrarySheet: View {
    let completeConnection: (
        AroHubInfo,
        URL,
        String,
        OfflineDownloadPolicy
    ) -> Void
    var willPauseSharing = false
    var initialAddress = ""

    @Environment(\.dismiss) private var dismiss
    @State private var browser = AroHubBrowser()
    @State private var selectedHubID: UUID?
    @State private var manualAddress = ""
    @State private var code = ""
    @State private var showingManual = false
    @State private var showingScanner = false
    @State private var status = "Looking for your Aro libraries…"
    @State private var pairingTask: Task<Void, Never>?
    @State private var completedPairing: CompletedConnection?
    @State private var pairingRequestID: UUID?
    @State private var policy: OfflineDownloadPolicy = .stream
    @State private var selectedAlbums: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(completedPairing == nil ? "Connect to a Library" : "Offline Music")
                    .font(.largeTitle)
                Spacer()
                Button("Cancel") {
                    pairingTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            if willPauseSharing, completedPairing == nil {
                Label(
                    "When you connect, this Mac will stop sharing its local library. "
                        + "Your local music will remain here and you can switch back later.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let completedPairing {
                downloadPreferences(completedPairing)
            } else {
                discoveryContent
            }
        }
        .padding(28)
        .frame(width: 600, height: 600)
        .onAppear {
            if manualAddress.isEmpty, !initialAddress.isEmpty {
                manualAddress = initialAddress
                showingManual = true
                status = "Enter the current connection code to repair this library."
            }
            browser.restart()
        }
        .onDisappear {
            browser.stop()
            pairingTask?.cancel()
        }
        .sheet(isPresented: $showingScanner) {
            scannerContent
        }
    }

    private var discoveryContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Libraries nearby")
                .font(.title2.weight(.semibold))
            if browser.hubs.isEmpty {
                ContentUnavailableView(
                    browser.isSearching
                        ? "Looking for libraries…"
                        : "No libraries found",
                    systemImage: browser.isSearching
                        ? "dot.radiowaves.left.and.right"
                        : "wifi.slash",
                    description: Text(
                        browser.isSearching
                            ? "Discovery updates automatically."
                            : "Make sure the other Aro library is online and sharing is enabled."
                    )
                )
            } else {
                ForEach(browser.hubs) { hub in
                    Button {
                        selectedHubID = hub.id
                        manualAddress = hub.address
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "macbook.and.iphone")
                                .font(.title2)
                            VStack(alignment: .leading) {
                                Text(hub.name)
                                    .font(.headline)
                                Text("Available now · Same local network")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedHubID == hub.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding()
                    .background(
                        selectedHubID == hub.id
                            ? Color.accentColor.opacity(0.12)
                            : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
            }

            HStack {
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                }
                Button("Can’t see your library?") {
                    showingManual.toggle()
                }
                .buttonStyle(.link)
                Spacer()
                Button("Try Again") { browser.restart() }
            }

            if showingManual {
                GroupBox("Manual connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField(
                            "Library address",
                            text: $manualAddress,
                            prompt: Text("https://aro-example.local:4848")
                        )
                        Text(
                            "Use this only when automatic discovery cannot find the other Aro library."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

            TextField("Six-digit connection code", text: $code)
                .textFieldStyle(.roundedBorder)
                .onChange(of: code) {
                    code = String(code.filter(\.isNumber).prefix(6))
                }
            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let pairingRequestID {
                GroupBox("Pairing request ID") {
                    HStack {
                        Text(pairingRequestID.uuidString)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                pairingRequestID.uuidString,
                                forType: .string
                            )
                        }
                    }
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }
        }
    }

    private func downloadPreferences(
        _ connection: CompletedConnection
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How should music be stored on this Mac?")
                .font(.title2.weight(.semibold))
            policyChoice(
                .stream,
                title: "Stream as I listen",
                detail: "Uses very little storage. Recently played music remains available temporarily.",
                recommended: true
            )
            policyChoice(
                .favourites,
                title: "Keep favourites offline",
                detail: "Favourite songs remain downloaded on this Mac."
            )
            policyChoice(
                .selectedAlbums(selectedAlbums),
                title: "Keep selected albums offline",
                detail: "Choose albums after the first library update."
            )
            policyChoice(
                .fullLibrary,
                title: "Keep the full library offline",
                detail: "Downloads every available song to this Mac."
            )
            Spacer()
            HStack {
                Text("You can change this later in Devices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Finish") {
                    finish(connection)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var scannerContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan a Aro Code")
                .font(.title)
            PairingCodeScanner { value in
                guard let url = URL(string: value),
                      let invitation = PairingInvitationPayload(url: url) else {
                    status = "That QR code is not a valid Aro invitation."
                    return
                }
                manualAddress = invitation.address.absoluteString
                code = invitation.code
                showingManual = true
                showingScanner = false
                status = "Invitation ready. Select Connect to request access."
            } onError: { message in
                status = message
                showingScanner = false
            }
            .frame(minWidth: 520, minHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("Point this Mac’s camera at the code shown by the library host.")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 570, height: 470)
    }

    private var canConnect: Bool {
        code.count == 6 && URL(string: manualAddress)?.scheme == "https"
            && pairingTask == nil
    }

    private func policyChoice(
        _ value: OfflineDownloadPolicy,
        title: String,
        detail: String,
        recommended: Bool = false
    ) -> some View {
        Button {
            policy = value
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(
                    systemName: policyKind(policy) == policyKind(value)
                        ? "largecircle.fill.circle"
                        : "circle"
                )
                .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(title).font(.headline)
                        if recommended {
                            Text("Recommended")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func connect() {
        guard let url = URL(string: manualAddress) else { return }
        pairingTask?.cancel()
        status = "Sending a connection request…"
        pairingRequestID = nil
        pairingTask = Task {
            defer { pairingTask = nil }
            do {
                let deviceID = libraryDeviceID
                let client = AroSyncClient(pairingBaseURL: url)
                _ = try await client.compatibleHubInfo()
                let pairing = try await client.startPairing(
                    deviceID: deviceID,
                    deviceName: Host.current().localizedName ?? "Mac",
                    code: code
                )
                pairingRequestID = pairing.requestID
                status = "Waiting for approval from the library owner…"
                for _ in 0 ..< 150 {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .seconds(2))
                    switch try await client.pollPairing(pairing: pairing) {
                    case .pending:
                        continue
                    case .approved(let completed):
                        let secureClient = AroSyncClient(
                            baseURL: url,
                            pinnedTLSFingerprint: completed.tlsFingerprint
                        )
                        let info = try await secureClient.compatibleHubInfo()
                        try FileHubCredentialStore().save(
                            completed.credential,
                            hubID: info.hubID
                        )
                        completedPairing = CompletedConnection(
                            info: info,
                            baseURL: url,
                            fingerprint: completed.tlsFingerprint,
                            credential: completed.credential
                        )
                        status = "Approved"
                        return
                    case .rejected:
                        status = "The library owner denied this request."
                        return
                    case .expired:
                        status = "The connection code expired. Generate a new code from the Aro library."
                        return
                    }
                }
                status = "The connection code expired. Try another code."
            } catch is CancellationError {
                return
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func finish(_ connection: CompletedConnection) {
        completeConnection(
            connection.info,
            connection.baseURL,
            connection.fingerprint,
            policy
        )
        dismiss()
    }

    private var libraryDeviceID: UUID {
        if let value = UserDefaults.standard.string(
            forKey: "library.deviceID"
        ).flatMap(UUID.init(uuidString:)) {
            return value
        }
        let value = UUID()
        UserDefaults.standard.set(value.uuidString, forKey: "library.deviceID")
        return value
    }

    private func policyKind(_ policy: OfflineDownloadPolicy) -> String {
        switch policy {
        case .stream: "stream"
        case .favourites: "favourites"
        case .selectedAlbums: "albums"
        case .fullLibrary: "full"
        }
    }
}

private struct CompletedConnection {
    let info: AroHubInfo
    let baseURL: URL
    let fingerprint: String
    let credential: HubDeviceCredential
}
