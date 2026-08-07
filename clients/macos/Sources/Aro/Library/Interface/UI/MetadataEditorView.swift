import SwiftUI
import AroCommon

struct MetadataEditorView: View {
    let context: MetadataEditorContext
    let snapshot: TrackMetadataSnapshot
    let save: ([ManualMetadataEdit], ManualArtworkEdit?) -> Void
    let reset: () -> Void
    /// Covers the hub has already found. A cache read, so this is immediate. `nil` on a
    /// library with no hub to ask, in which case the picker shows only what's held locally.
    let loadHubArtwork: (() async -> [HubArtworkCandidate])?
    /// Searches the Cover Art Archive. Runs for a minute or more, so it reports through a
    /// job rather than blocking; returns true once the search has finished.
    let searchHubArtwork: (() async -> Bool)?
    /// Pulls the full-resolution image for a chosen candidate; `nil` leaves the thumbnail
    /// in place rather than failing the selection outright.
    let resolveHubArtwork: ((HubArtworkCandidate) async -> Data?)?

    @Environment(\.dismiss) private var dismiss
    @State private var values: [EditableMetadataField: String]
    @State private var artworkEdit: ManualArtworkEdit?
    @State private var showResetConfirmation = false
    @State private var hubArtwork: [HubArtworkCandidate] = []
    @State private var hubArtworkLoading = false
    @State private var hubArtworkSearching = false
    /// Set once a search has completed, so an empty result can be reported as "nothing is
    /// archived for this album" rather than "not looked yet".
    @State private var hubArtworkSearched = false
    @State private var hubArtworkError: String?
    @State private var resolvingArtwork: HubArtworkCandidate?

    init(
        context: MetadataEditorContext,
        snapshot: TrackMetadataSnapshot,
        save: @escaping ([ManualMetadataEdit], ManualArtworkEdit?) -> Void,
        reset: @escaping () -> Void,
        loadHubArtwork: (() async -> [HubArtworkCandidate])? = nil,
        searchHubArtwork: (() async -> Bool)? = nil,
        resolveHubArtwork: ((HubArtworkCandidate) async -> Data?)? = nil
    ) {
        self.context = context
        self.snapshot = snapshot
        self.save = save
        self.reset = reset
        self.loadHubArtwork = loadHubArtwork
        self.searchHubArtwork = searchHubArtwork
        self.resolveHubArtwork = resolveHubArtwork
        _values = State(initialValue: snapshot.effectiveValues)
        _artworkEdit = State(initialValue: nil)
    }

    private var fields: [EditableMetadataField] {
        switch context.scope {
        case .track:
            [.artist, .album, .title, .genre, .releaseYear, .trackNumber, .discNumber]
        case .album:
            [.artist, .album, .genre, .releaseYear]
        case .artist:
            [.artist]
        }
    }

    private var title: String {
        switch context.scope {
        case .track: "Track Metadata"
        case .album: "Album Metadata"
        case .artist: "Artist Metadata"
        }
    }

    private var edits: [ManualMetadataEdit] {
        fields.compactMap { field in
            let original = snapshot.effectiveValues[field] ?? ""
            let proposed = (values[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard proposed != original else { return nil }
            return ManualMetadataEdit(
                field: field,
                value: proposed.isEmpty ? nil : proposed
            )
        }
    }

    private var hasInvalidNumber: Bool {
        fields.contains { field in
            guard field.isNumeric else { return false }
            let value = (values[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && (Int(value) ?? 0) <= 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title2.bold())
                    Text(scopeSummary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(fields, id: \.self) { field in
                        metadataField(field)
                        if field == .album, context.scope != .artist {
                            artworkField
                        }
                    }

                    Label(
                        "Manual changes are Aro's golden master. Scans and online identification will never replace them.",
                        systemImage: "seal.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    Label(
                        "Aro stores these changes in its library. Your audio files are left "
                            + "untouched unless you write metadata back to them from the "
                            + "Metadata screen.",
                        systemImage: "lock.doc"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
            }

            Divider()

            HStack {
                Button("Reset Metadata…", role: .destructive) {
                    showResetConfirmation = true
                }
                .disabled(!hasManualMetadata)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(edits, artworkEdit)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((edits.isEmpty && artworkEdit == nil) || hasInvalidNumber)
            }
            .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 680)
        .confirmationDialog(
            "Reset metadata for (scopeSummary.lowercased())?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Metadata", role: .destructive) {
                reset()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes manual golden-master values and reveals the latest identified or original-file metadata.")
        }
    }

    private var scopeSummary: String {
        switch context.scope {
        case .track:
            snapshot.song.title
        case .album:
            "\(context.songs.count) tracks in \(snapshot.song.album ?? "Unknown Album")"
        case .artist:
            "\(context.songs.count) tracks by \(snapshot.song.artist)"
        }
    }

    private var hasManualMetadata: Bool {
        context.songs.count > 1
            || !snapshot.manualFields.isDisjoint(with: fields)
            || snapshot.manualArtworkSet
    }

    @ViewBuilder
    private func metadataField(_ field: EditableMetadataField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(field.label)
                    .font(.headline)
                if snapshot.manualFields.contains(field) {
                    Label("Golden master", systemImage: "seal.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 8) {
                TextField(field.label, text: valueBinding(field))
                    .textFieldStyle(.roundedBorder)

                let suggestions = snapshot.candidates(
                    for: field,
                    selectedArtist: values[.artist] ?? ""
                )
                Menu("Suggestions") {
                    ForEach(MetadataCandidate.Source.allCases, id: \.self) { source in
                        let sourceValues = suggestions.filter { $0.source == source }
                        if !sourceValues.isEmpty {
                            Section(source.rawValue) {
                                ForEach(sourceValues, id: \.self) { candidate in
                                    Button(candidate.value) {
                                        values[field] = candidate.value
                                    }
                                }
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(suggestions.isEmpty)
            }

            if field.isNumeric,
               !(values[field] ?? "").isEmpty,
               (Int(values[field] ?? "") ?? 0) <= 0 {
                Text("Enter a positive whole number.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func valueBinding(_ field: EditableMetadataField) -> Binding<String> {
        Binding(
            get: { values[field] ?? "" },
            set: { values[field] = $0 }
        )
    }

    private var visibleArtworkCandidates: [ArtworkCandidate] {
        snapshot.artworkCandidates(
            selectedArtist: values[.artist] ?? "",
            selectedAlbum: values[.album] ?? ""
        )
    }

    private var artworkField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("Artwork")
                    .font(.headline)
                if snapshot.manualArtworkSet || artworkEdit != nil {
                    Label("Golden master", systemImage: "seal.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    artworkButton(data: nil, label: "No Artwork")
                    ForEach(visibleArtworkCandidates, id: \.self) { candidate in
                        artworkButton(
                            data: candidate.data,
                            label: candidate.source.rawValue
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)

            hubArtworkSection(
                title: "Other Pressings of This Album",
                origin: .thisAlbum,
                empty: "No other cover art is archived for this album."
            )
            hubArtworkSection(
                title: artistCatalogueTitle,
                origin: .artistCatalogue,
                empty: "No cover art is archived for this artist's other albums."
            )
            hubArtworkSearchControl
        }
        .task(id: snapshot.song.libraryID) {
            guard let loadHubArtwork, hubArtwork.isEmpty else { return }
            hubArtworkLoading = true
            hubArtwork = await loadHubArtwork()
            hubArtworkLoading = false
        }
    }

    private var artistCatalogueTitle: String {
        let artist = (values[.artist] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? "Other Albums by This Artist" : "Other Albums by \(artist)"
    }

    /// Covers the hub found, split by where they came from. Kept separate from the local
    /// candidates above because they mean different things: those are images this Mac
    /// already holds, these are what exists in the archive but hasn't been chosen.
    ///
    /// The section always renders and always states which of the four situations it is in.
    /// It previously hid itself whenever it had nothing to show, so a failed search looked
    /// identical to an album with no artwork — a spinner, and then the section silently
    /// disappearing.
    @ViewBuilder
    private func hubArtworkSection(
        title: String,
        origin: RemoteArtworkOrigin,
        empty: String
    ) -> some View {
        let candidates = hubArtwork.filter { $0.origin == origin }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if hubArtworkLoading || hubArtworkSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.top, 4)

            if !candidates.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(candidates) { candidate in
                            hubArtworkButton(candidate)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            } else if hubArtworkSearching {
                Text("Searching the Cover Art Archive… this can take a minute or two.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let hubArtworkError {
                Text(hubArtworkError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if hubArtworkSearched {
                Text(empty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !hubArtworkLoading {
                Text("Not searched yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Searching is explicit rather than automatic. A cold search walks up to twelve
    /// pressings and twenty-five release-groups at MusicBrainz's ~1 request/second, so
    /// running it every time the editor opened would cost minutes of somebody else's rate
    /// limit for a window that is usually opened to correct a typo.
    @ViewBuilder
    private var hubArtworkSearchControl: some View {
        if searchHubArtwork != nil {
            HStack(spacing: 8) {
                Button(hubArtworkSearched ? "Search Again" : "Find More Artwork") {
                    Task { await runArtworkSearch() }
                }
                .disabled(hubArtworkSearching)
                if hubArtworkSearching {
                    ProgressView().controlSize(.small)
                }
                Text("Looks for other pressings and albums in the Cover Art Archive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    private func runArtworkSearch() async {
        guard let searchHubArtwork, let loadHubArtwork else { return }
        hubArtworkSearching = true
        hubArtworkError = nil
        let finished = await searchHubArtwork()
        hubArtworkSearching = false
        guard finished else {
            hubArtworkError = "Couldn't search the archive. Check the library connection and try again."
            return
        }
        hubArtworkSearched = true
        hubArtwork = await loadHubArtwork()
    }

    private func hubArtworkButton(_ candidate: HubArtworkCandidate) -> some View {
        let resolving = resolvingArtwork == candidate
        return Button {
            // The grid holds thumbnails; the full-resolution image is only worth
            // fetching for the one a listener actually settles on. Show the thumbnail
            // immediately so the choice registers, then upgrade it in place.
            artworkEdit = ManualArtworkEdit(data: candidate.thumbnail)
            guard let resolveHubArtwork else { return }
            resolvingArtwork = candidate
            Task {
                let full = await resolveHubArtwork(candidate)
                if let full, artworkEdit?.data == candidate.thumbnail {
                    artworkEdit = ManualArtworkEdit(data: full)
                }
                resolvingArtwork = nil
            }
        } label: {
            VStack(spacing: 5) {
                AlbumArtworkView(data: candidate.thumbnail, maxDimension: 78)
                    .frame(width: 78, height: 78)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                artworkEdit?.data == candidate.thumbnail
                                    ? Color.accentColor
                                    : Color.clear,
                                lineWidth: 3
                            )
                    }
                    .overlay {
                        if resolving {
                            ProgressView().controlSize(.small)
                        }
                    }
                Text(candidate.album ?? "Cover")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 92)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select artwork from \(candidate.album ?? "the archive")")
    }

    private func artworkButton(data: Data?, label: String) -> some View {
        let selected = if let artworkEdit {
            artworkEdit.data == data
        } else {
            snapshot.song.artworkData == data
        }
        return Button {
            artworkEdit = ManualArtworkEdit(data: data)
        } label: {
            VStack(spacing: 5) {
                AlbumArtworkView(data: data, maxDimension: 78)
                    .frame(width: 78, height: 78)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                selected ? Color.accentColor : Color.clear,
                                lineWidth: 3
                            )
                    }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 92)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(label)")
    }
}
