import AroCommon
import SwiftUI

/// "Metadata": shows the background AcoustID/MusicBrainz identification queue, lets
/// the user kick off identification for the whole library at once, and lists albums
/// so a specific one can be (re-)synced without touching the rest of the library.
struct MetadataView: View {
    let songs: [Song]
    @Bindable var preferences: SyncPreferences
    @Bindable var profileRegistry: LibraryProfileRegistry
    let syncStore: SQLiteSyncOperationStore

    @State private var localServers = LocalAroServerMonitor()
    @State private var status: IdentificationStatus?
    @State private var statusMessage: String?
    @State private var searchText = ""
    @State private var pollTask: Task<Void, Never>?
    @State private var showingIdentificationSettings = false

    private var albums: [LibraryAlbum] {
        AlbumLibrary.albums(from: songs)
    }

    private var filteredAlbums: [LibraryAlbum] {
        albums.filter {
            FuzzySearch.matches(searchText, in: $0.name + " " + $0.artistName)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if preferences.acoustidApiKey.isEmpty {
                ContentUnavailableView {
                    Label("No AcoustID API Key", systemImage: "key.slash")
                } description: {
                    Text(
                        "Add a free AcoustID API key in Metadata settings to "
                            + "identify song, artist, album, and artwork metadata."
                    )
                } actions: {
                    Button("Set Up Identification") {
                        showingIdentificationSettings = true
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                queueSummary

                Divider()

                List(filteredAlbums) { album in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.name)
                                .font(AroFont.headline)
                                .lineLimit(1)
                            Text(album.artistName)
                                .font(AroFont.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Button("Sync Album Data") {
                            Task { await syncAlbumData(album.songs) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 7)
                }
                .searchable(text: $searchText, prompt: "Search Albums")
            }
        }
        .task {
            localServers.refresh()
            await refreshStatus()
            pollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    await refreshStatus()
                }
            }
        }
        .onDisappear {
            pollTask?.cancel()
        }
        .sheet(isPresented: $showingIdentificationSettings) {
            TrackIdentificationSettingsView(preferences: preferences)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Metadata")
                    .font(AroFont.largeTitle)
                Text("Background identification via AcoustID and MusicBrainz")
                    .font(AroFont.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button("Sync All Music Metadata") {
                Task { await syncAllMetadata() }
            }
            .disabled(preferences.acoustidApiKey.isEmpty || songs.isEmpty)

            Button {
                showingIdentificationSettings = true
            } label: {
                Label("Identification Settings", systemImage: "gearshape")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var queueSummary: some View {
        HStack(spacing: 24) {
            summaryStat(label: "Queued", value: status?.queued ?? 0)
            summaryStat(label: "Processed", value: status?.processed ?? 0)
            summaryStat(label: "Failed", value: status?.failed ?? 0)

            if status?.inFlight == true {
                Label("Identifying…", systemImage: "waveform")
                    .font(AroFont.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)

        if let lastError = status?.lastError {
            Label(lastError, systemImage: "exclamationmark.triangle.fill")
                .font(AroFont.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }

        if let localServersError = localServers.errorMessage {
            Label(localServersError, systemImage: "exclamationmark.triangle.fill")
                .font(AroFont.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }

        if let statusMessage {
            Text(statusMessage)
                .font(AroFont.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
    }

    private func summaryStat(label: String, value: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(AroFont.headline)
                .monospacedDigit()
            Text(label)
                .font(AroFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var syncBridge: IdentificationSyncBridge {
        IdentificationSyncBridge(
            dataLocation: preferences.dataLocation,
            localServers: localServers.servers,
            remoteProfile: profileRegistry.activeProfile,
            syncStore: syncStore,
            libraryDeviceID: libraryDeviceID
        )
    }

    private var libraryDeviceID: UUID {
        UserDefaults.standard.string(forKey: "library.deviceID")
            .flatMap(UUID.init(uuidString:))
            ?? UUID()
    }

    private func refreshStatus() async {
        status = await syncBridge.status()
    }

    private func syncAllMetadata() async {
        localServers.refresh()
        guard !songs.isEmpty else {
            statusMessage = "No songs with a readable local file were found "
                + "(\(songs.count) song(s) had no usable file fingerprint)."
            return
        }
        do {
            let queued = try await syncBridge.identify(songs)
            statusMessage = queueMessage(queued, requested: songs.count)
        } catch {
            statusMessage = error.localizedDescription
        }
        await refreshStatus()
    }

    private func syncAlbumData(_ albumSongs: [Song]) async {
        localServers.refresh()
        guard !albumSongs.isEmpty else {
            statusMessage = "No songs with a readable local file were found in this album."
            return
        }
        do {
            let queued = try await syncBridge.identify(albumSongs)
            statusMessage = queueMessage(queued, requested: albumSongs.count)
        } catch {
            statusMessage = error.localizedDescription
        }
        await refreshStatus()
    }

    private func queueMessage(_ queued: Int, requested: Int) -> String {
        guard queued > 0 else {
            return "No songs were queued. The active library could not resolve "
                + "a stored file for any of the \(requested) selected song(s)."
        }
        return "Queued \(queued) song(s) for identification."
    }
}
