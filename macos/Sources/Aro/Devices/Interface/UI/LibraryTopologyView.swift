import AroCommon
import Foundation
import SwiftUI

/// A visual overview of where a library lives and which Aro devices currently
/// depend on it. The map intentionally uses only confirmed pairing/source state;
/// grey edges mean a remembered relationship, never a claimed live connection.
struct LibraryTopologyView: View {
    let profile: LibraryProfile
    let songCount: Int
    let sources: [ControlledSourceFolder]
    let devices: [ControlledHubDevice]
    let currentDeviceID: UUID
    let activeTransfers: UInt64
    let livePlayback: [RemoteTopologyPlayback]
    let localHubOnline: Bool

    @State private var selected: TopologyNode = .hub

    private var isRemoteHub: Bool { profile.kind == .remote }
    private var currentClientName: String { Host.current().localizedName ?? "This Mac" }
    private var otherDevices: [ControlledHubDevice] { devices.filter { $0.id != currentDeviceID } }
    private var thisClientActivity: RemoteTopologyPlayback? {
        livePlayback.first { $0.deviceID == currentDeviceID }
    }

    private func activity(for deviceID: UUID) -> RemoteTopologyPlayback? {
        livePlayback.first { $0.deviceID == deviceID }
    }

    var body: some View {
        SettingsCard(title: "Topology") {
            VStack(alignment: .leading, spacing: 14) {
                Text("How this library, its music, and your devices connect")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 18) {
                    map
                        .frame(minHeight: 270)
                    inspector
                        .frame(width: 220, alignment: .topLeading)
                }

                HStack(spacing: 14) {
                    legend("Live", color: .green)
                    legend("Needs attention", color: .orange)
                    legend("Remembered / offline", color: .secondary)
                    Spacer()
                    Text("Refreshes while Settings is open")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if activeTransfers > 0 {
                    Label(
                        "Hub is serving \(activeTransfers) active \(activeTransfers == 1 ? "stream" : "streams")",
                        systemImage: "arrow.left.arrow.right.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var map: some View {
        GeometryReader { proxy in
            let hub = CGPoint(x: proxy.size.width * 0.50, y: proxy.size.height * 0.50)
            let client = CGPoint(x: proxy.size.width * 0.50, y: proxy.size.height * 0.84)
            let sourcePoints = sources.enumerated().map { index, _ in
                CGPoint(x: proxy.size.width * 0.14, y: 54 + CGFloat(index) * 74)
            }
            let devicePoints = otherDevices.enumerated().map { index, _ in
                CGPoint(x: proxy.size.width * 0.86, y: 54 + CGFloat(index) * 74)
            }
            ZStack {
                Canvas { context, _ in
                    context.stroke(
                        Path { path in path.move(to: hub); path.addLine(to: client) },
                        with: .color(.green.opacity(0.8)), lineWidth: 2.5
                    )
                    for point in sourcePoints {
                        context.stroke(
                            Path { path in path.move(to: point); path.addLine(to: hub) },
                            with: .color(.secondary.opacity(0.35)), lineWidth: 1.5
                        )
                    }
                    for (index, point) in devicePoints.enumerated() {
                        let active = activity(for: otherDevices[index].id) != nil
                        context.stroke(
                            Path { path in path.move(to: hub); path.addLine(to: point) },
                            with: .color(active ? .green.opacity(0.8) : .secondary.opacity(0.35)),
                            style: StrokeStyle(lineWidth: active ? 2.5 : 1.5, dash: active ? [] : [5, 4])
                        )
                    }
                }

                topologyNode(
                    .hub,
                    title: profile.name,
                    subtitle: "\(songCount) songs · \(localHubOnline ? "Online" : "Offline")",
                    icon: "music.note.house.fill",
                    color: localHubOnline ? .accentColor : .orange
                )
                    .position(hub)

                topologyNode(
                    .client,
                    title: currentClientName,
                    subtitle: clientStatus,
                    icon: "laptopcomputer.and.arrow.down",
                    color: .green
                )
                .position(client)

                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                    topologyNode(
                        .source(source.id),
                        title: source.name,
                        subtitle: source.available ? "Music source" : "Unavailable",
                        icon: source.available ? "externaldrive.fill" : "externaldrive.badge.exclamationmark",
                        color: source.available ? .cyan : .orange
                    )
                    .position(sourcePoints[index])
                }

                ForEach(Array(otherDevices.enumerated()), id: \.element.id) { index, device in
                    topologyNode(
                        .device(device.id),
                        title: device.name,
                        subtitle: deviceStatus(device),
                        icon: deviceIcon(device),
                        color: deviceColor(device)
                    )
                    .position(devicePoints[index])
                }
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library topology")
    }

    private func topologyNode(
        _ node: TopologyNode,
        title: String,
        subtitle: String,
        icon: String,
        color: Color
    ) -> some View {
        Button { selected = node } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Text(title).lineLimit(1).font(.caption.weight(.semibold))
                Text(subtitle).lineLimit(1).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 128, height: 72)
            .padding(4)
            .background(color.opacity(selected == node ? 0.16 : 0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == node ? color : .secondary.opacity(0.2), lineWidth: selected == node ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var inspector: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(inspectorTitle, systemImage: inspectorIcon)
                .font(.headline)
            Text(inspectorDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .device(let id) = selected, let device = devices.first(where: { $0.id == id }) {
                Divider()
                Label(device.allowsContributions ? "Can contribute music" : "Read-only access", systemImage: device.allowsContributions ? "arrow.up.circle.fill" : "eye")
                    .font(.caption)
                if let count = device.offlineTrackCount {
                    Label("\(count) songs kept offline", systemImage: "arrow.down.circle")
                        .font(.caption)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    private var inspectorTitle: String {
        switch selected {
        case .hub: profile.name
        case .client: currentClientName
        case .source(let id): sources.first(where: { $0.id == id })?.name ?? "Music source"
        case .device(let id): devices.first(where: { $0.id == id })?.name ?? "Device"
        }
    }

    private var inspectorIcon: String {
        switch selected { case .hub: "music.note.house.fill"; case .client: "laptopcomputer.and.arrow.down"; case .source: "externaldrive.fill"; case .device: "laptopcomputer" }
    }

    private var inspectorDetail: String {
        switch selected {
        case .hub:
            if isRemoteHub {
                return "Remote Aro server for this library. This Mac connects to it as a client."
            }
            return localHubOnline ? "This Mac is hosting the library for paired Aro devices." : "Sharing is off or the local hub is not currently reachable."
        case .client:
            if let activity = thisClientActivity {
                return listeningDetail(activity) + " This Mac is connected to \(profile.name) as a library client."
            }
            return "This Mac is connected to \(profile.name) as a library client."
        case .source(let id):
            guard let source = sources.first(where: { $0.id == id }) else { return "Source unavailable." }
            return source.available
                ? "\(source.songCount) source files are indexed here; duplicate audio is counted once by the library."
                : (source.lastError ?? "This source is currently unavailable.")
        case .device(let id):
            guard let device = devices.first(where: { $0.id == id }) else { return "Device unavailable." }
            if let activity = activity(for: id) {
                return listeningDetail(activity)
            }
            return device.lastSeenAt.map { "Last seen \($0.formatted(.relative(presentation: .named)))." } ?? "Paired, but not recently seen."
        }
    }

    private func deviceStatus(_ device: ControlledHubDevice) -> String {
        if let activity = activity(for: device.id) {
            return activity.state == .buffering ? "Buffering" : "Playing"
        }
        return device.lastSeenAt.map { "Last seen \($0.formatted(.relative(presentation: .named)))" } ?? "Offline"
    }

    private func deviceColor(_ device: ControlledHubDevice) -> Color {
        if let activity = activity(for: device.id) {
            return activity.state == .buffering ? .orange : .green
        }
        guard let seen = device.lastSeenAt else { return .secondary }
        return Date().timeIntervalSince(seen) < 120 ? .green : .orange
    }

    private func deviceIcon(_ device: ControlledHubDevice) -> String {
        switch device.deviceType?.lowercased() {
        case let value where value?.contains("phone") == true: "iphone"
        case let value where value?.contains("tablet") == true: "ipad"
        default: "laptopcomputer"
        }
    }

    private var clientStatus: String {
        guard let activity = thisClientActivity else { return "This Mac · Client" }
        return activity.state == .buffering ? "This Mac · Buffering" : "This Mac · Playing"
    }

    private func listeningDetail(_ activity: RemoteTopologyPlayback) -> String {
        let route = activity.playback.output?.routeName ?? "the system audio output"
        let state = activity.state == .buffering ? "Buffering" : "Playing"
        let format = [
            activity.playback.output?.sampleRate.map { "\(Int($0 / 1_000)) kHz" },
            activity.playback.output?.bitDepth.map { "\($0)-bit" }
        ].compactMap { $0 }.joined(separator: " · ")
        return "\(state) through \(route)\(format.isEmpty ? "." : " (\(format)).")"
    }

    private func legend(_ title: String, color: Color) -> some View {
        Label(title, systemImage: "circle.fill").font(.caption).foregroundStyle(color)
    }
}

private enum TopologyNode: Hashable {
    case hub
    case client
    case source(UUID)
    case device(UUID)
}
