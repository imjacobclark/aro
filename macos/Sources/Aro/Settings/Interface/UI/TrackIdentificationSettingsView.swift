import AroCommon
import SwiftUI

/// Settings for the background track-identification pipeline: the personal AcoustID
/// API key it authenticates with, and whether identified metadata gets written back
/// into original audio files.
struct TrackIdentificationSettingsView: View {
    @Bindable var preferences: SyncPreferences

    @Environment(\.dismiss) private var dismiss
    @State private var localServers = LocalAroServerMonitor()
    @State private var persistMetadataToFiles = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Identification Settings")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Form {
                Section {
                    SecureField(
                        "AcoustID API Key",
                        text: $preferences.acoustidApiKey
                    )
                    Text(
                        "Get a free personal key at acoustid.org. Aro uses it to "
                            + "identify music and fetch canonical metadata and artwork."
                    )
                    .font(AroFont.footnote)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(
                        "Write Identified Metadata to Original Files",
                        isOn: $persistMetadataToFiles
                    )
                    .disabled(preferences.acoustidApiKey.isEmpty)
                    .onChange(of: persistMetadataToFiles) { _, newValue in
                        Task { await updatePersistSetting(newValue) }
                    }
                    Text(
                        "Aro always keeps identified metadata in its library. Enable "
                            + "this only if the original audio files should also change."
                    )
                    .font(AroFont.footnote)
                    .foregroundStyle(.secondary)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(AroFont.footnote)
                        .foregroundStyle(.secondary)
                }

                if let localServersError = localServers.errorMessage {
                    Text(localServersError)
                        .font(AroFont.footnote)
                        .foregroundStyle(.secondary)
                }

                if let preferencesError = preferences.errorMessage {
                    Text(preferencesError)
                        .font(AroFont.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 390)
        .task {
            localServers.refresh()
            await loadPersistSetting()
        }
    }

    private var controlClient: HubControlClient? {
        let dataLocation = LibrarySettingsView.controlDataLocation(
            preferred: preferences.dataLocation,
            servers: localServers.servers
        )
        guard let dataLocation, !dataLocation.isEmpty else { return nil }
        return HubControlClient(
            socketURL: URL(fileURLWithPath: dataLocation)
                .appendingPathComponent("control.sock")
        )
    }

    private func loadPersistSetting() async {
        guard let controlClient else { return }
        do {
            persistMetadataToFiles = try await controlClient.boolSetting(
                key: "persist_metadata_to_files"
            ) ?? false
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func updatePersistSetting(_ value: Bool) async {
        guard let controlClient else {
            statusMessage = "Aro cannot reach the Background Service to save this setting."
            return
        }
        do {
            try await controlClient.setSetting(key: "persist_metadata_to_files", value: value)
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

}
