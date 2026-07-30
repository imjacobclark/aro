import AroCommon
import SwiftUI

struct OutputRoutePopover: View {
    @Bindable var preferences: PlaybackPreferences
    @Bindable var deviceManager: AudioDeviceManager
    let playback: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
            .frame(maxWidth: .infinity)

            Divider()

            AirPlayRouteControl(
                mediaURL: playback.currentSong?.url,
                routeSelectionDidFinish: {
                    preferences.outputDeviceUID = nil
                    deviceManager.refresh()
                    playback.restartForPlaybackSettingsChange()
                }
            )
            .frame(maxWidth: .infinity)

            if let selected = deviceManager.selectedDevice(for: preferences.outputDeviceUID), selected.transport.isWireless {
                Label("Shared normalized playback may add latency.", systemImage: "waveform.path.ecg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Playback")
                .font(.headline)

            Picker("Playback Mode", selection: $preferences.mode) {
                ForEach(PlaybackMode.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .onChange(of: preferences.mode) {
                playback.restartForPlaybackSettingsChange()
            }

            if deviceManager.selectedDevice(
                for: preferences.outputDeviceUID
            )?.transport.isWireless != true {
                Toggle(
                    "Exclusive Access",
                    isOn: $preferences.hogModeEnabled
                )
                .help(
                    "Temporarily gives Aro sole access to the selected output device."
                )
                .onChange(of: preferences.hogModeEnabled) {
                    playback.restartForPlaybackSettingsChange()
                }
            }

            LabeledContent("Loudness Target") {
                HStack(spacing: 8) {
                    Slider(
                        value: $preferences.targetLUFS,
                        in: -24 ... -8,
                        step: 1
                    )
                    Text("\(Int(preferences.targetLUFS)) LUFS")
                        .monospacedDigit()
                        .frame(width: 62, alignment: .trailing)
                }
            }
            .disabled(preferences.mode != .normalized)
            .onChange(of: preferences.targetLUFS) {
                playback.refreshNormalizedGain()
            }

            Text(
                preferences.mode == .bitPerfect
                    ? "Bit-Perfect uses native sample rates, unity gain, and no audio processing."
                    : "Normalized applies constant gain with a −1 dB peak ceiling."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 350)
        .onAppear {
            deviceManager.refresh()
        }
    }
}
