import AroCommon
import SwiftUI

struct OutputRoutePopover: View {
    @Bindable var preferences: PlaybackPreferences
    @Bindable var deviceManager: AudioDeviceManager
    @Bindable var playback: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Output")
                .font(.headline)
            Picker("Output Device", selection: Binding(
                get: { preferences.outputDeviceUID ?? "" },
                set: { newValue in
                    preferences.outputDeviceUID = newValue.isEmpty ? nil : newValue
                    playback.restartForPlaybackSettingsChange()
                }
            )) {
                Text("System Default").tag("")
                ForEach(AudioOutputTransport.allCases, id: \.self) { transport in
                    let matching = deviceManager.devices.filter { $0.transport == transport }
                    if !matching.isEmpty {
                        Section(transport.displayName) {
                            ForEach(matching) { device in
                                Label(device.name, systemImage: transport.systemImageName)
                                    .tag(device.uid)
                            }
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(width: 250)

            Divider()

            AirPlayRouteControl(
                mediaURL: playback.currentSong?.url,
                routeSelectionDidFinish: {
                    preferences.outputDeviceUID = nil
                    deviceManager.refresh()
                    playback.restartForPlaybackSettingsChange()
                }
            )
            .frame(width: 310)

            if let selected = deviceManager.selectedDevice(for: preferences.outputDeviceUID), selected.transport.isWireless {
                Label("Shared normalized playback may add latency.", systemImage: "waveform.path.ecg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
