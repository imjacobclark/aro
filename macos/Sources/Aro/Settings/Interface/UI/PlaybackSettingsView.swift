import AppKit
import AroCommon
import Observation
import SwiftUI

struct PlaybackSettingsView<
    DeviceManager: AudioDeviceManaging & Observable
>: View {
    @Bindable var preferences: PlaybackPreferences
    @Bindable var deviceManager: DeviceManager
    let playback: PlaybackController
    let libraryFileManager: any LibraryFileManaging
    @State private var databaseError: String?

    var body: some View {
        Form {
            Picker("Playback Mode", selection: $preferences.mode) {
                ForEach(PlaybackMode.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }

            Picker(
                "Output Device",
                selection: Binding(
                    get: { preferences.outputDeviceUID ?? "" },
                    set: { preferences.outputDeviceUID = $0.isEmpty ? nil : $0 }
                )
            ) {
                Text("System Default").tag("")
                ForEach(AudioOutputTransport.allCases, id: \.self) { transport in
                    let matching = deviceManager.devices.filter { $0.transport == transport }
                    if !matching.isEmpty {
                        Section(transport.displayName) {
                            ForEach(matching) { device in
                                Label(device.name, systemImage: transport.systemImageName).tag(device.uid)
                            }
                        }
                    }
                }
            }

            AirPlayRouteControl(
                mediaURL: playback.currentSong?.url,
                routeSelectionDidFinish: {
                    preferences.outputDeviceUID = nil
                    deviceManager.refresh()
                    playback.restartForPlaybackSettingsChange()
                }
            )

            Toggle("Exclusive Access", isOn: $preferences.hogModeEnabled)
                .disabled(deviceManager.selectedDevice(for: preferences.outputDeviceUID)?.transport.isWireless == true)
                .help(
                    "Temporarily gives Aro sole access to the selected output device."
                )

            LabeledContent("Loudness Target") {
                HStack {
                    Slider(value: $preferences.targetLUFS, in: -24 ... -8, step: 1)
                        .frame(width: 180)
                    Text("\(Int(preferences.targetLUFS)) LUFS")
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                }
            }
            .disabled(preferences.mode != .normalized)

            Text(
                preferences.mode == .bitPerfect
                    ? "Bit-Perfect mode uses native sample rates, unity gain, and no audio processing."
                    : "Normalized mode applies constant gain with a −1 dB peak ceiling."
            )
            .font(AroFont.footnote)
            .foregroundStyle(.secondary)

            if let selected = deviceManager.selectedDevice(for: preferences.outputDeviceUID), selected.transport.isWireless {
                Label("Wireless routes use shared normalized playback and may introduce latency.", systemImage: "waveform.path.ecg")
                    .font(AroFont.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            LabeledContent("Library Database") {
                Text(libraryFileManager.libraryURL.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .help(libraryFileManager.libraryURL.path)
            }

            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        libraryFileManager.libraryURL
                    ])
                }
                Button("Export Library…") {
                    exportLibrary()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 380)
        .onAppear {
            deviceManager.refresh()
        }
        .onChange(of: preferences.mode) {
            playback.restartForPlaybackSettingsChange()
        }
        .onChange(of: preferences.outputDeviceUID) {
            playback.restartForPlaybackSettingsChange()
        }
        .onChange(of: preferences.hogModeEnabled) {
            playback.restartForPlaybackSettingsChange()
        }
        .onChange(of: preferences.targetLUFS) {
            playback.refreshNormalizedGain()
        }
        .alert(
            "Unable to Export Library",
            isPresented: Binding(
                get: { databaseError != nil },
                set: { if !$0 { databaseError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(databaseError ?? "Unknown database error.")
        }
    }

    private func exportLibrary() {
        let panel = NSSavePanel()
        panel.title = "Export Aro Library"
        panel.nameFieldStringValue = "Aro Library.sqlite3"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        do {
            try libraryFileManager.exportLibrary(to: destination)
        } catch {
            databaseError = error.localizedDescription
        }
    }
}
