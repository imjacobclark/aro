import SwiftUI

struct MetadataEditorView: View {
    let context: MetadataEditorContext
    let snapshot: TrackMetadataSnapshot
    let save: ([ManualMetadataEdit], ManualArtworkEdit?) -> Void
    let reset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [EditableMetadataField: String]
    @State private var artworkEdit: ManualArtworkEdit?
    @State private var showResetConfirmation = false

    init(
        context: MetadataEditorContext,
        snapshot: TrackMetadataSnapshot,
        save: @escaping ([ManualMetadataEdit], ManualArtworkEdit?) -> Void,
        reset: @escaping () -> Void
    ) {
        self.context = context
        self.snapshot = snapshot
        self.save = save
        self.reset = reset
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
                        "Aro stores these changes in its library only. The original or managed audio file is never modified.",
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
        }
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
