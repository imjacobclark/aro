import AroCommon
import SwiftUI

/// "Metadata": the identification queue, and what Aro's metadata actually looks like
/// against the files it came from.
///
/// Two modes, because they answer different questions. **Sync** is about running
/// identification — everything at once, or one album. **Differences** is about the result:
/// Aro deliberately never lets identification overwrite a file's tags, so the two drift,
/// and until now nothing surfaced that. Playing a track shows Aro's value and gives no hint
/// the file disagrees.
struct MetadataView: View {
    let songs: [Song]
    @Bindable var preferences: SyncPreferences
    @Bindable var profileRegistry: LibraryProfileRegistry
    let syncStore: SQLiteSyncOperationStore

    /// Owned by `ContentView`, not this view: `MetadataView` is torn down and
    /// rebuilt every time the sidebar selection leaves Metadata and comes back,
    /// which would otherwise reset a local `@State` and re-show a false
    /// "Identification Not Enabled" empty state (gated on `remoteHubInfo`) until
    /// the hub round trip completes again. Binding to values that outlive this
    /// view gives Metadata a stale-while-revalidate feel: last known queue
    /// status and hub info render immediately, refreshed quietly in the background.
    @Binding var status: IdentificationStatus?
    @Binding var remoteHubInfo: AroHubInfo?

    @State private var localServers = LocalAroServerMonitor()
    @State private var statusMessage: String?
    @State private var searchText = ""
    @State private var pollTask: Task<Void, Never>?
    @State private var showingIdentificationSettings = false
    @State private var mode: Mode = .sync
    @State private var deltas: [RemoteTrackMetadataDelta] = []
    @State private var loadingDeltas = false
    @State private var deltaError: String?
    @State private var expanded: Set<String> = []
    @State private var onlyDifferences = true
    @State private var writeBackEnabled = false
    @State private var writing: Set<String> = []
    /// Tracks awaiting confirmation. Writing changes files the user owns, so it is always
    /// confirmed against a count rather than happening on the click that asked for it.
    @State private var pendingWrite: [RemoteTrackMetadataDelta] = []
    @State private var writeReport: String?

    /// Loads metadata differences from the hub. `nil` when there is no hub to ask, which
    /// hides the Differences mode rather than offering something that cannot work.
    var loadDeltas: ((String?) async -> [RemoteTrackMetadataDelta]?)?

    /// Writes Aro's metadata into the given tracks' own files, returning what happened to
    /// each. Some will be refused — a file that has drifted since Aro read it is left
    /// alone — so the caller reports per track rather than pass or fail.
    var writeBack: (([String]) async -> [RemoteMetadataWriteBackOutcome]?)?

    /// Identifies a scope the hub resolves itself — an artist, an album, or the whole
    /// library when both are nil. `nil` when there is no hub, in which case syncing falls
    /// back to posting the tracks the client already holds.
    var sweep: ((String?, String?) async -> Int?)?

    /// Whether the hub permits its files to be modified at all. Asked before showing the
    /// action, so the app never offers a button it knows will be refused.
    var loadWriteBackEnabled: (() async -> Bool)?

    enum Mode: String, CaseIterable, Identifiable {
        case sync = "Sync"
        case differences = "Differences"

        var id: String { rawValue }
    }

    /// AcoustID configuration lives on whichever machine is actually running
    /// the hub. For a `.local` profile that's `preferences.acoustidApiKey`
    /// (this Mac's own Background Service); for a `.remote` profile it's a
    /// capability flag read from that hub's own `/v1/hub` response --
    /// `preferences.acoustidApiKey` is this Mac's *own* key and has nothing
    /// to do with someone else's server.
    private var isRemoteProfile: Bool {
        profileRegistry.activeProfile?.kind == .remote
    }

    private var identificationIsAvailable: Bool {
        isRemoteProfile
            ? (remoteHubInfo?.identificationAvailable ?? false)
            : !preferences.acoustidApiKey.isEmpty
    }

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

            if !identificationIsAvailable {
                ContentUnavailableView {
                    Label(
                        isRemoteProfile ? "Identification Not Enabled" : "No AcoustID API Key",
                        systemImage: "key.slash"
                    )
                } description: {
                    Text(
                        isRemoteProfile
                            ? "Ask the owner of \(remoteHubInfo?.displayName ?? "this library") "
                                + "to add an AcoustID API key on their server to enable "
                                + "song, artist, album, and artwork identification."
                            : "Add a free AcoustID API key in Metadata settings to "
                                + "identify song, artist, album, and artwork metadata."
                    )
                } actions: {
                    if !isRemoteProfile {
                        Button("Set Up Identification") {
                            showingIdentificationSettings = true
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                queueSummary

                if loadDeltas != nil {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }

                Divider()

                if mode == .differences, loadDeltas != nil {
                    differencesList
                } else {
                    albumSyncList
                }
            }
        }
        // Without this the stack takes its children's intrinsic height and the window
        // centres it, leaving the screen floating in a band of empty space whenever a
        // branch renders something short — an empty state, or an error.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: mode) {
            guard mode == .differences else { return }
            writeBackEnabled = await loadWriteBackEnabled?() ?? false
            guard deltas.isEmpty else { return }
            await refreshDeltas()
        }
        .confirmationDialog(
            pendingWrite.count == 1
                ? "Write Aro's metadata into this file?"
                : "Write Aro's metadata into \(pendingWrite.count) files?",
            isPresented: .constant(!pendingWrite.isEmpty),
            titleVisibility: .visible
        ) {
            Button("Write to Files") {
                let tracks = pendingWrite
                pendingWrite = []
                Task { await performWriteBack(tracks) }
            }
            Button("Cancel", role: .cancel) { pendingWrite = [] }
        } message: {
            Text(
                "These are your own audio files, not Aro's copies. Aro will change their "
                    + "tags on disk. Any file that has been edited since Aro last read it "
                    + "is left alone."
            )
        }
        .alert(
            "Finished writing",
            isPresented: .constant(writeReport != nil),
            presenting: writeReport
        ) { _ in
            Button("OK") { writeReport = nil }
        } message: { report in
            Text(report)
        }
        .task {
            localServers.refresh()
            await refreshStatus()
            await refreshRemoteHubInfo()
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
            TrackIdentificationSettingsView(
                preferences: preferences,
                isRemoteProfile: isRemoteProfile,
                remoteHubInfo: remoteHubInfo
            )
        }
    }

    /// Running identification, album by album. Unchanged in intent from before — this is
    /// still where you ask the hub to go and look something up.
    private var albumSyncList: some View {
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

    private var visibleDeltas: [RemoteTrackMetadataDelta] {
        deltas
            .filter { !onlyDifferences || $0.differenceCount > 0 }
            .filter {
                FuzzySearch.matches(
                    searchText,
                    in: [$0.title, $0.artist, $0.album].compactMap { $0 }.joined(separator: " ")
                )
            }
    }

    /// What Aro holds against what the files say, grouped by album and expandable to the
    /// fields that actually disagree.
    ///
    /// Defaults to showing only tracks with a difference: on a healthy library most tracks
    /// agree, and listing them all at equal weight buries the handful that don't.
    @ViewBuilder
    private var differencesList: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Only show differences", isOn: $onlyDifferences)
                    .toggleStyle(.checkbox)
                Spacer()
                if loadingDeltas {
                    ProgressView().controlSize(.small)
                }
                if writeBackEnabled, !writableWithDifferences.isEmpty {
                    Button("Write \(writableWithDifferences.count) to Files") {
                        pendingWrite = writableWithDifferences
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!writing.isEmpty)
                }
                Button("Refresh") { Task { await refreshDeltas() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(loadingDeltas)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            if let deltaError {
                ContentUnavailableView(
                    "Couldn't compare metadata",
                    systemImage: "exclamationmark.triangle",
                    description: Text(deltaError)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadingDeltas && deltas.isEmpty {
                ProgressView("Reading your files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleDeltas.isEmpty {
                ContentUnavailableView(
                    onlyDifferences ? "Everything matches" : "Nothing to compare",
                    systemImage: onlyDifferences
                        ? "checkmark.seal"
                        : "questionmark.folder",
                    description: Text(
                        onlyDifferences
                            ? "Aro's metadata agrees with every file it can read."
                            : "No tracks in this library have readable files to compare."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleDeltas) { delta in
                    deltaRow(delta)
                }
                .searchable(text: $searchText, prompt: "Search Tracks")
            }
        }
    }

    @ViewBuilder
    private func deltaRow(_ delta: RemoteTrackMetadataDelta) -> some View {
        let isExpanded = expanded.contains(delta.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(delta.title ?? "Unknown Track")
                        .font(AroFont.headline)
                        .lineLimit(1)
                    Text(
                        [delta.artist, delta.album]
                            .compactMap { $0 }
                            .joined(separator: " — ")
                    )
                    .font(AroFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                availabilityBadge(delta)

                if delta.differenceCount > 0 {
                    Text("\(delta.differenceCount) differ")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }

                if writeBackEnabled, delta.writable, delta.differenceCount > 0 {
                    if writing.contains(delta.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Write to File") { pendingWrite = [delta] }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                Button(isExpanded ? "Hide" : "Compare") {
                    if isExpanded {
                        expanded.remove(delta.id)
                    } else {
                        expanded.insert(delta.id)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isExpanded {
                fieldComparison(delta)
            }
        }
        .padding(.vertical, 7)
    }

    /// The three availability states, distinguished because they mean different things:
    /// Aro holding a copy keeps a track playable, but only a reachable original could ever
    /// have corrected tags written into it.
    private func availabilityBadge(_ delta: RemoteTrackMetadataDelta) -> some View {
        let symbol: String
        let tint: Color
        switch delta.availability {
        case .originalAndCopy:
            symbol = "externaldrive.badge.checkmark"
            tint = .secondary
        case .originalOnly:
            symbol = "doc"
            tint = .secondary
        case .copyOnly:
            symbol = "externaldrive"
            tint = .orange
        case .missing:
            symbol = "exclamationmark.triangle"
            tint = .red
        }
        return Image(systemName: symbol)
            .foregroundStyle(tint)
            .help(delta.availability.label + " — " + delta.availability.detail)
    }

    private func fieldComparison(_ delta: RemoteTrackMetadataDelta) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(delta.fields.filter { !onlyDifferences || $0.verdict.isDifference }) { field in
                HStack(alignment: .top, spacing: 10) {
                    Text(field.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                    // Aro's value leads because it is what the listener sees; the file's
                    // value is the thing that might need correcting.
                    Text(field.aro ?? "—")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: field.verdict.isDifference ? "arrow.left.arrow.right" : "equal")
                        .font(.caption2)
                        .foregroundStyle(field.verdict.isDifference ? .orange : .secondary)
                    Text(field.file ?? "—")
                        .font(.caption)
                        .foregroundStyle(field.verdict.isDifference ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: 6) {
                Text("Aro").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                Text("library value").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("").frame(width: 14)
                Text("file on disk").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 2)

            if let path = delta.originalPath {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.leading, 4)
        .padding(.top, 2)
    }

    private func refreshDeltas() async {
        guard let loadDeltas else { return }
        loadingDeltas = true
        deltaError = nil
        let loaded = await loadDeltas(nil)
        loadingDeltas = false
        guard let loaded else {
            deltaError = "The library didn't answer. Check the connection and try again."
            return
        }
        deltas = loaded
    }

    /// The tracks a bulk write would actually touch: those that disagree with their file
    /// and whose original is still reachable. Offering "write everything" when half the
    /// selection cannot be written would make the count a lie.
    private var writableWithDifferences: [RemoteTrackMetadataDelta] {
        visibleDeltas.filter { $0.writable && $0.differenceCount > 0 }
    }

    /// Writes, then reloads — a written file has a new content hash, so every delta held
    /// here refers to bytes that no longer exist and must not be shown as current.
    private func performWriteBack(_ tracks: [RemoteTrackMetadataDelta]) async {
        guard let writeBack else { return }
        let ids = tracks.map(\.contentHash)
        writing.formUnion(ids)
        let outcomes = await writeBack(ids)
        writing.subtract(ids)

        guard let outcomes else {
            writeReport = "The library didn't answer, so nothing is known to have been written."
            return
        }
        let written = outcomes.filter(\.written).count
        let refused = outcomes.filter { !$0.written }
        var report = written == 1 ? "1 file updated." : "\(written) files updated."
        // The first refusal's own words rather than a count: "the file has changed since
        // Aro last read it" tells the user what to go and look at, and a bulk write
        // usually fails for one reason rather than many.
        if let first = refused.first {
            report += refused.count == 1
                ? "\n\n1 was left alone: \(first.error ?? "no reason given")"
                : "\n\n\(refused.count) were left alone, the first because: "
                    + (first.error ?? "no reason given")
        }
        writeReport = report
        await refreshDeltas()
    }

    private func refreshRemoteHubInfo() async {
        guard isRemoteProfile,
              let baseURL = profileRegistry.activeProfile?.baseURL,
              let tlsFingerprint = syncStore.membership(baseURL: baseURL)?.tlsFingerprint
        else {
            remoteHubInfo = nil
            return
        }
        // A transiently unreachable hub must not blank an already-known-good value --
        // same "keep showing the last known answer" rule `HomeView.refresh()` follows
        // for playlists. Without this, one dropped request would flash "Identification
        // Not Enabled" even though nothing about the hub's actual state changed.
        guard let fetched = try? await AroSyncClient(
            baseURL: baseURL,
            pinnedTLSFingerprint: tlsFingerprint
        ).hubInfo() else {
            return
        }
        remoteHubInfo = fetched
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
            .disabled(!identificationIsAvailable || songs.isEmpty)

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
                // Named rather than merely counted: identification works a folder at a
                // time, so "Art Angels — 15 tracks" says what three ticking counters
                // cannot, and the hub has been sending it all along.
                Label(
                    status?.lastGroup?.releaseTitle
                        ?? status?.lastGroup?.folder.map(lastPathComponent)
                        ?? "Identifying…",
                    systemImage: "waveform"
                )
                .font(AroFont.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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

    /// The hub reports a folder as an absolute path on its own filesystem, which is long
    /// and mostly irrelevant here — the last component is the album.
    private func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
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
            profile: profileRegistry.activeProfile,
            syncStore: syncStore,
            libraryDeviceID: libraryDeviceID,
            localAdminToken: preferences.localAdminToken
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
        // Ask the hub to work out what "everything" is where possible: it holds the
        // catalogue, and it can also see tracks this client never synced a folder for.
        if let sweep {
            if let queued = await sweep(nil, nil) {
                statusMessage = queued == 0
                    ? "Everything in this library has already been identified."
                    : "Queued \(queued) track(s) for identification."
            } else {
                statusMessage = "The library didn't answer, so nothing was queued."
            }
            await refreshStatus()
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
