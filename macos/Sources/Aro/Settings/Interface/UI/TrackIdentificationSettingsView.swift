import AroCommon
import SwiftUI

/// Settings for the background track-identification pipeline: the personal AcoustID
/// API key it authenticates with. Identified and manual metadata always remains in
/// Aro's library database; source audio files are immutable inputs.
struct TrackIdentificationSettingsView: View {
    @Bindable var preferences: SyncPreferences
    /// AcoustID configuration lives on whichever machine runs the hub. For a
    /// `.remote` profile, `preferences.acoustidApiKey` is this Mac's *own*
    /// key and has nothing to do with someone else's server -- editing it
    /// here would silently do nothing for the connected library, so this
    /// view shows read-only status instead (see `MetadataView`, which reads
    /// the same distinction).
    var isRemoteProfile: Bool = false
    var remoteHubInfo: AroHubInfo?

    @Environment(\.dismiss) private var dismiss
    @State private var localServers = LocalAroServerMonitor()

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
                if isRemoteProfile {
                    Section {
                        Label(
                            remoteHubInfo?.identificationAvailable == true
                                ? "Identification is enabled on \(remoteHubInfo?.displayName ?? "this library")."
                                : "Identification is not enabled on "
                                    + "\(remoteHubInfo?.displayName ?? "this library").",
                            systemImage: remoteHubInfo?.identificationAvailable == true
                                ? "checkmark.circle"
                                : "key.slash"
                        )
                        Text(
                            "The AcoustID key that powers this belongs to the library "
                                + "owner's server, not this Mac. Ask them to add or "
                                + "change it there."
                        )
                        .font(AroFont.footnote)
                        .foregroundStyle(.secondary)
                    }
                } else {
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
                        Label(
                            "Original Files Are Never Modified",
                            systemImage: "lock.doc"
                        )
                        Text(
                            "Identified and manually corrected metadata is stored in Aro's "
                                + "library and used for browsing, sync, and export. Referenced "
                                + "and managed source audio is never retagged."
                        )
                        .font(AroFont.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if !isRemoteProfile, let localServersError = localServers.errorMessage {
                    Text(localServersError)
                        .font(AroFont.footnote)
                        .foregroundStyle(.secondary)
                }

                if !isRemoteProfile, let preferencesError = preferences.errorMessage {
                    Text(preferencesError)
                        .font(AroFont.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 390)
        .task {
            guard !isRemoteProfile else { return }
            localServers.refresh()
        }
    }

}
