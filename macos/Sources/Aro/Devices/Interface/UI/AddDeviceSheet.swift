import SwiftUI

struct AddDeviceSheet: View {
    let controlClient: HubControlClient
    let onDevicesChanged: ([ControlledHubDevice]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var invitation: HubPairingWindow?
    @State private var hubStatus: HubControlStatus?
    @State private var requests: [ControlledPairingRequest] = []
    @State private var errorMessage: String?
    @State private var allowContributions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Add a Device")
                    .font(.largeTitle)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if let invitation, let hubStatus {
                if requests.isEmpty {
                    invitationContent(invitation, hubStatus: hubStatus)
                } else {
                    approvalContent
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Couldn’t create a connection code",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                Button("Try Again", action: openInvitation)
                    .keyboardShortcut(.defaultAction)
            } else {
                ProgressView("Preparing a secure invitation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(28)
        .frame(width: 540, height: 620)
        .task {
            openInvitation()
        }
        .task(id: invitation?.code) {
            guard invitation != nil else { return }
            while !Task.isCancelled {
                await refreshRequests()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private func invitationContent(
        _ invitation: HubPairingWindow,
        hubStatus: HubControlStatus
    ) -> some View {
        Text("Open Aro on your other device and scan this code.")
            .font(.title3)
        PairingQRCodeView(
            payload: pairingURL(
                invitation: invitation,
                hubStatus: hubStatus
            ).absoluteString
        )
        .frame(width: 250, height: 250)
        .frame(maxWidth: .infinity)

        VStack(spacing: 8) {
            Text("Or enter this connection code")
                .foregroundStyle(.secondary)
            Text(formatted(invitation.code))
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel("Connection code \(invitation.code)")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(expiryText(invitation.expiresAt, now: context.date))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        Spacer()
        HStack {
            Label(
                "Only devices you approve can connect.",
                systemImage: "lock.shield"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            Spacer()
            Button("New Code", action: openInvitation)
        }
    }

    private var approvalContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connection request")
                .font(.title2.weight(.semibold))
            Text("Choose whether this device can use your music library.")
                .foregroundStyle(.secondary)
            Toggle(isOn: $allowContributions) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Allow this device to add music")
                    Text(
                        "Off by default. Enable this only for a device you trust to contribute files to this library."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            ForEach(requests) { request in
                HStack(spacing: 14) {
                    Image(systemName: "laptopcomputer")
                        .font(.title)
                        .frame(width: 42, height: 42)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(request.deviceName)
                            .font(.headline)
                        Text(
                            "\(request.deviceType ?? "Device") · On your local network"
                        )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(request.requestID.uuidString)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            request.requestID.uuidString,
                            forType: .string
                        )
                    } label: {
                        Label("Copy ID", systemImage: "doc.on.doc")
                    }
                    Button("Deny", role: .destructive) {
                        approve(request, allowed: false)
                    }
                    Button("Allow") {
                        approve(request, allowed: true)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding()
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            }
            Spacer()
        }
    }

    private func openInvitation() {
        invitation = nil
        hubStatus = nil
        requests = []
        errorMessage = nil
        Task {
            do {
                async let status = controlClient.status()
                async let window = controlClient.openPairing()
                hubStatus = try await status
                invitation = try await window
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshRequests() async {
        do {
            requests = try await controlClient.pendingPairingRequests()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func approve(
        _ request: ControlledPairingRequest,
        allowed: Bool
    ) {
        Task {
            do {
                try await controlClient.approvePairing(
                    requestID: request.requestID,
                    approve: allowed,
                    canContribute: allowed && allowContributions
                )
                requests.removeAll { $0.id == request.id }
                onDevicesChanged(try await controlClient.devices())
                if allowed {
                    dismiss()
                } else {
                    openInvitation()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func pairingURL(
        invitation: HubPairingWindow,
        hubStatus: HubControlStatus
    ) -> URL {
        let label = hubStatus.hubID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
        var components = URLComponents()
        components.scheme = "aro"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "hub", value: hubStatus.hubID.uuidString),
            URLQueryItem(
                name: "address",
                value: "https://aro-\(label).local:4848"
            ),
            URLQueryItem(name: "code", value: invitation.code),
            URLQueryItem(
                name: "expires",
                value: String(Int(invitation.expiresAt.timeIntervalSince1970))
            ),
        ]
        return components.url!
    }

    private func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    private func expiryText(_ expiry: Date, now: Date) -> String {
        let remaining = max(0, Int(expiry.timeIntervalSince(now)))
        if remaining == 0 {
            return "Code expired"
        }
        return "Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))"
    }
}
