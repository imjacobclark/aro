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

            // Reads the live system default rather than a stored preference, and writing
            // changes the system default. That is what stops the picker and the macOS Sound
            // menu disagreeing: there is one setting, shown in two places.
            Picker("Output Device", selection: Binding(
                get: { deviceManager.defaultDevice?.uid ?? "" },
                set: { newValue in
                    guard let device = deviceManager.devices.first(where: { $0.uid == newValue }) else {
                        return
                    }
                    preferences.outputDeviceUID = device.uid
                    deviceManager.setSystemDefaultOutputDevice(device)
                    playback.restartForPlaybackSettingsChange()
                }
            )) {
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
                    // AirPlay changes the system default itself; refreshing lets the
                    // ordinary follow-the-system path pick it up, rather than Aro
                    // discarding the selection as it used to.
                    deviceManager.refresh()
                }
            )
            .frame(maxWidth: .infinity)

            if let selected = deviceManager.defaultDevice, selected.transport.isWireless {
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

            if deviceManager.defaultDevice?.transport.isWireless != true {
                Toggle(
                    "Exclusive Access",
                    isOn: $preferences.hogModeEnabled
                )
                .help(
                    "Gives Aro sole access to the output device. Other apps will not be able to play through it."
                )
                .onChange(of: preferences.hogModeEnabled) {
                    playback.restartForPlaybackSettingsChange()
                }
                if preferences.hogModeEnabled {
                    // Aro follows the system output device, so exclusive access takes over
                    // the device everything else is using. Worth saying plainly rather than
                    // leaving someone to wonder why their video call went silent.
                    Text("Other apps can't play through \(deviceManager.defaultDevice?.name ?? "this device") while this is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .disabled(playback.effectiveMode != .normalized)
            .onChange(of: preferences.targetLUFS) {
                playback.refreshNormalizedGain()
            }

            // Describes what is actually happening, not what was asked for: a wireless
            // route forces normalized playback, and this used to claim unity gain and no
            // processing while gain was in fact being applied.
            Text(
                playback.isModeOverriddenByRoute
                    ? "This route can't do Bit-Perfect, so Normalized is in use: constant gain with a −1 dB peak ceiling."
                    : (playback.effectiveMode == .bitPerfect
                        ? "Bit-Perfect uses native sample rates, unity gain, and no audio processing. Volume and loudness are unavailable because they would break bit-exactness."
                        : "Normalized applies constant gain with a −1 dB peak ceiling.")
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
