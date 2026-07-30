import AroCommon
import SwiftUI

struct OfflineMusicSettingsSheet: View {
    let profile: LibraryProfile
    let albums: [String]
    @Bindable var registry: LibraryProfileRegistry
    @Bindable var mediaCache: MediaCacheController

    @Environment(\.dismiss) private var dismiss
    @State private var policy: OfflineDownloadPolicy
    @State private var selectedAlbums: Set<String>
    @State private var usesAutomaticLimit: Bool
    @State private var limitGiB: Int
    @State private var showingResetConfirmation = false
    @State private var showingRemovedConfirmation = false

    init(
        profile: LibraryProfile,
        albums: [String],
        registry: LibraryProfileRegistry,
        mediaCache: MediaCacheController
    ) {
        self.profile = profile
        self.albums = albums
        self.registry = registry
        self.mediaCache = mediaCache
        _policy = State(initialValue: profile.offlinePolicy)
        if case .selectedAlbums(let selected) = profile.offlinePolicy {
            _selectedAlbums = State(initialValue: selected)
        } else {
            _selectedAlbums = State(initialValue: [])
        }
        _usesAutomaticLimit = State(
            initialValue: profile.storageLimitBytes == nil
        )
        _limitGiB = State(
            initialValue: Int(
                (profile.storageLimitBytes
                    ?? CacheEvictionPolicy.defaultLimitBytes)
                    / (1_024 * 1_024 * 1_024)
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Streaming & Storage")
                .font(.largeTitle)

            Picker("Mode", selection: resiliencyMode) {
                Text("Keep Entire Library").tag(ResiliencyMode.resilient)
                Text("Stream Music").tag(ResiliencyMode.stream)
            }
            .pickerStyle(.segmented)

            switch resiliencyMode.wrappedValue {
            case .resilient:
                resilientExplanation
            case .stream:
                streamOptions
            }

            Divider()

            HStack {
                Text(
                    "\(mediaCache.downloadedFileCount) downloaded · "
                        + ByteCountFormatter.string(
                            fromByteCount: mediaCache.usedBytes,
                            countStyle: .file
                        )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                Spacer()
                Menu("Storage Maintenance") {
                    Button("Delete Removed Downloads…", role: .destructive) {
                        showingRemovedConfirmation = true
                    }
                    Button("Reset Temporary Downloads…", role: .destructive) {
                        showingResetConfirmation = true
                    }
                }
            }

            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560, height: sheetHeight)
        .confirmationDialog(
            "Delete downloads removed from the source library?",
            isPresented: $showingRemovedConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Removed Downloads", role: .destructive) {
                mediaCache.deleteRemovedDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Only downloaded copies are deleted. The source library is not changed."
            )
        }
        .confirmationDialog(
            "Reset temporary offline downloads?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Downloads", role: .destructive) {
                mediaCache.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Temporary downloads will be removed. Protected music remains available."
            )
        }
    }

    private var resilientExplanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                "This Mac mirrors the entire library",
                systemImage: "checkmark.icloud.fill"
            )
            .font(.headline)
            .foregroundStyle(.green)

            Text(
                "Every song is downloaded and kept here as a redundant, resilient backup. If your Aro server ever becomes unreachable or goes away, this Mac keeps the library playable and exportable."
            )
            .foregroundStyle(.secondary)

            Label(
                "Aro will use as much disk space as the library requires. Storage limits can’t be set in this mode.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.orange)
        }
    }

    private var streamOptions: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(
                "Choose whether streamed music is transient or retained for faster replay. Retained music is not a backup."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Picker("Download behaviour", selection: streamSubPolicy) {
                Label(
                    "Stream only",
                    systemImage: "dot.radiowaves.left.and.right"
                )
                .tag(StreamSubPolicy.streamOnly)
                Label(
                    "Keep recently played",
                    systemImage: "clock.arrow.circlepath"
                )
                .tag(StreamSubPolicy.recent)
                Label(
                    "Keep favourite albums or songs",
                    systemImage: "heart.fill"
                )
                .tag(StreamSubPolicy.favourites)
            }
            .pickerStyle(.radioGroup)

            Text(streamModeExplanation)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if streamSubPolicy.wrappedValue == .favourites {
                GroupBox("Favourite albums") {
                    if albums.isEmpty {
                        Text("Albums will appear after the library finishes updating.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading) {
                                ForEach(albums, id: \.self) { album in
                                    Toggle(
                                        album,
                                        isOn: Binding(
                                            get: {
                                                selectedAlbums.contains(album)
                                            },
                                            set: { selected in
                                                if selected {
                                                    selectedAlbums.insert(album)
                                                } else {
                                                    selectedAlbums.remove(album)
                                                }
                                                policy = .selectedAlbums(
                                                    selectedAlbums
                                                )
                                            }
                                        )
                                    )
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                        .padding(.top, 4)
                    }
                }
            }

            if streamSubPolicy.wrappedValue != .streamOnly {
                GroupBox("Storage limit") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Choose automatically", isOn: $usesAutomaticLimit)
                        if usesAutomaticLimit {
                            Text(
                                "Aro uses the lower of 20 GB or 10% of currently available disk space."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        } else {
                            Stepper(
                                "\(limitGiB) GB",
                                value: $limitGiB,
                                in: 1 ... 2_048,
                                step: 5
                            )
                            .accessibilityLabel("Storage limit")
                            .accessibilityValue("\(limitGiB) gigabytes")
                        }
                    }
                    .padding(.top, 4)
                }
            }

            if streamSubPolicy.wrappedValue != .streamOnly {
                Text(
                    "Stored music is removed automatically when necessary to stay within this limit."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var streamModeExplanation: String {
        switch streamSubPolicy.wrappedValue {
        case .streamOnly:
            "Audio is buffered only while it plays. Aro never retains streamed songs or uses the offline storage limit."
        case .recent:
            "Completed streams remain available for recent listening until Aro needs the space."
        case .favourites:
            "Favourite songs and the albums selected below are downloaded first, up to the storage limit."
        }
    }

    private var sheetHeight: CGFloat {
        switch resiliencyMode.wrappedValue {
        case .resilient:
            300
        case .stream:
            switch streamSubPolicy.wrappedValue {
            case .streamOnly:
                400
            case .recent:
                500
            case .favourites:
                640
            }
        }
    }

    private var resiliencyMode: Binding<ResiliencyMode> {
        Binding {
            if case .fullLibrary = policy {
                return .resilient
            }
            return .stream
        } set: { mode in
            switch mode {
            case .resilient:
                policy = .fullLibrary
            case .stream:
                policy = .streamOnly
            }
        }
    }

    private var streamSubPolicy: Binding<StreamSubPolicy> {
        Binding {
            switch policy {
            case .streamOnly: .streamOnly
            case .stream: .recent
            case .favourites, .selectedAlbums: .favourites
            case .fullLibrary: .streamOnly
            }
        } set: { kind in
            switch kind {
            case .streamOnly:
                policy = .streamOnly
            case .recent:
                policy = .stream
            case .favourites:
                policy = .selectedAlbums(selectedAlbums)
            }
        }
    }

    private func save() {
        var updated = profile
        updated.offlinePolicy = policy
        let isResilient = resiliencyMode.wrappedValue == .resilient
        let isStreamOnly = streamSubPolicy.wrappedValue == .streamOnly
        updated.storageLimitBytes =
            isResilient || isStreamOnly || usesAutomaticLimit
            ? nil
            : Int64(limitGiB) * 1_024 * 1_024 * 1_024
        registry.update(updated)
        Task {
            await mediaCache.apply(
                policy,
                storageLimitBytes: updated.storageLimitBytes
            )
        }
        dismiss()
    }
}

private enum ResiliencyMode: Hashable {
    case resilient
    case stream
}

private enum StreamSubPolicy: Hashable {
    case streamOnly
    case recent
    case favourites
}
