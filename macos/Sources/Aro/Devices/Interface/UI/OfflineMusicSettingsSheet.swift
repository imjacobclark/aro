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
            Text("Offline Music")
                .font(.largeTitle)
            Picker("Download behaviour", selection: policyKind) {
                Text("Stream music as needed").tag(PolicyKind.stream)
                Text("Keep favourites offline").tag(PolicyKind.favourites)
                Text("Keep selected albums offline").tag(PolicyKind.albums)
                Text("Keep the full library offline").tag(PolicyKind.full)
            }
            .pickerStyle(.radioGroup)

            if policyKind.wrappedValue == .albums {
                GroupBox("Albums") {
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
                    }
                }
                .padding(.top, 4)
            }

            Text(
                "Favourites, selected albums, queued music, and the playing song are never removed automatically."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

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
        .frame(
            width: 560,
            height: policyKind.wrappedValue == .albums ? 570 : 410
        )
    }

    private var policyKind: Binding<PolicyKind> {
        Binding {
            switch policy {
            case .stream: .stream
            case .favourites: .favourites
            case .selectedAlbums: .albums
            case .fullLibrary: .full
            }
        } set: { kind in
            switch kind {
            case .stream: policy = .stream
            case .favourites: policy = .favourites
            case .albums: policy = .selectedAlbums(selectedAlbums)
            case .full: policy = .fullLibrary
            }
        }
    }

    private func save() {
        var updated = profile
        updated.offlinePolicy = policy
        updated.storageLimitBytes = usesAutomaticLimit
            ? nil
            : Int64(limitGiB) * 1_024 * 1_024 * 1_024
        registry.update(updated)
        Task {
            await mediaCache.apply(policy)
            mediaCache.enforceLimit(
                updated.storageLimitBytes
                    ?? CacheEvictionPolicy.defaultLimitBytes
            )
        }
        dismiss()
    }
}

private enum PolicyKind: Hashable {
    case stream
    case favourites
    case albums
    case full
}
