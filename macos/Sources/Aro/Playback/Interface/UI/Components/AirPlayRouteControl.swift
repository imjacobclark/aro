import AppKit
import AroCommon
@preconcurrency import AVKit
import CoreAudio
import SwiftUI

/// macOS gives apps no way to enumerate AirPlay device names directly (`AVRouteDetector`
/// only reports whether *any* extra routes exist). Picking a not-yet-paired device is only
/// possible through AVKit's own `AVRoutePickerView` popover.
///
/// Rather than layering a transparent `AVRoutePickerView` over the row and relying on
/// clicks landing on it, the row is a normal SwiftUI `Button` that triggers the picker
/// programmatically. The picker itself stays in the hierarchy (full-size but inert) purely
/// so the system popover anchors to this row.
struct AirPlayRouteControl: View {
    let mediaURL: URL?
    let routeSelectionDidFinish: @MainActor () -> Void
    @State private var airPlayRoutesDetected: Bool?
    @State private var isHovering = false
    @State private var controller = AirPlayRouteController()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                controller.presentRoutes()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)

                    AirPlayRoutePickerHost(
                        controller: controller,
                        mediaURL: mediaURL,
                        routeAvailabilityDidChange: { airPlayRoutesDetected = $0 },
                        routeSelectionDidFinish: routeSelectionDidFinish
                    )
                    .opacity(0.01)
                    .allowsHitTesting(false)

                    HStack(spacing: 10) {
                        Image(systemName: "airplayaudio")
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AirPlay and nearby devices")
                                .font(.subheadline.weight(.medium))
                            Text("Choose a TV, HomePod, or AirPlay speaker")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }

            if airPlayRoutesDetected == false {
                Text("Apple’s route detector currently reports no additional AirPlay routes.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// Holds a reference to the live `AVRoutePickerView` so the surrounding button can present
/// the system route popover on demand.
@MainActor
final class AirPlayRouteController {
    weak var pickerView: AVRoutePickerView?

    func presentRoutes() {
        // AVKit exposes no public API to present the route list, but the picker hosts a
        // standard NSButton whose action opens it, so clicking that is the supported path.
        guard let button = pickerView?.subviews.compactMap({ $0 as? NSButton }).first else {
            return
        }
        button.performClick(nil)
    }
}

private struct AirPlayRoutePickerHost: NSViewRepresentable {
    let controller: AirPlayRouteController
    let mediaURL: URL?
    let routeAvailabilityDidChange: @MainActor (Bool) -> Void
    let routeSelectionDidFinish: @MainActor () -> Void

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVRoutePickerViewDelegate {
        let detector = AVRouteDetector()
        let player = AVPlayer()
        var currentURL: URL?
        var defaultOutputDeviceIDBeforePresenting: AudioObjectID?
        let routeAvailabilityDidChange: @MainActor (Bool) -> Void
        let routeSelectionDidFinish: @MainActor () -> Void

        init(
            routeAvailabilityDidChange: @escaping @MainActor (Bool) -> Void,
            routeSelectionDidFinish: @escaping @MainActor () -> Void
        ) {
            self.routeAvailabilityDidChange = routeAvailabilityDidChange
            self.routeSelectionDidFinish = routeSelectionDidFinish
            detector.isRouteDetectionEnabled = true
            DispatchQueue.main.async { [detector, routeAvailabilityDidChange] in
                routeAvailabilityDidChange(detector.multipleRoutesDetected)
            }
        }

        func prepare(url: URL?) {
            guard currentURL != url else { return }
            currentURL = url
            player.pause()
            player.replaceCurrentItem(with: url.map(AVPlayerItem.init(url:)))
            player.allowsExternalPlayback = true
        }

        func routePickerViewDidEndPresentingRoutes(
            _ routePickerView: AVRoutePickerView
        ) {
            // AVKit calls this every time the popover closes, whether or not
            // the user actually picked a different route (dismissing with
            // Escape or a click-away fires it too). Only follow the new
            // system-default route if Core Audio's default output actually
            // changed as a result — otherwise this silently discards
            // whatever specific device the user had explicitly selected.
            let deviceIDBeforePresenting = defaultOutputDeviceIDBeforePresenting
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [routeSelectionDidFinish] in
                guard Self.currentDefaultOutputDeviceID() != deviceIDBeforePresenting else {
                    return
                }
                routeSelectionDidFinish()
            }
        }

        func routePickerViewWillBeginPresentingRoutes(
            _ routePickerView: AVRoutePickerView
        ) {
            defaultOutputDeviceIDBeforePresenting = Self.currentDefaultOutputDeviceID()
            routeAvailabilityDidChange(detector.multipleRoutesDetected)
        }

        private static func currentDefaultOutputDeviceID() -> AudioObjectID {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceID = AudioObjectID(0)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &deviceID
            ) == noErr else {
                return 0
            }
            return deviceID
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            routeAvailabilityDidChange: routeAvailabilityDidChange,
            routeSelectionDidFinish: routeSelectionDidFinish
        )
    }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.delegate = context.coordinator
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.labelColor, for: .normal)
        context.coordinator.prepare(url: mediaURL)
        view.player = mediaURL == nil ? nil : context.coordinator.player
        controller.pickerView = view
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        controller.pickerView = nsView
        context.coordinator.prepare(url: mediaURL)
        nsView.player = mediaURL == nil ? nil : context.coordinator.player
    }
}
