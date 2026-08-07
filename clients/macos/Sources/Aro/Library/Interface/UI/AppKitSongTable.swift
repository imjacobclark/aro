import AppKit
import AroCommon
import SwiftUI

/// An AppKit-owned song table.
///
/// SwiftUI's `Table` selection bridge can reapply an older binding value on
/// mouse-up when another observed value refreshes the table during a click.
/// Keeping selection inside `NSTableView` makes playback and cache refreshes
/// cell-only updates that cannot move the selected row.
struct AppKitSongTable: NSViewRepresentable {
    enum Presentation {
        case library
        case album

        var showsHeader: Bool {
            self == .library
        }

        var showsArtist: Bool {
            self == .library
        }

        var showsTrackNumber: Bool {
            self == .album
        }

        var showsDownloadStatus: Bool {
            self == .library
        }

        var scrollsVertically: Bool {
            self == .library
        }
    }

    let songs: [Song]
    let currentSongID: Song.ID?
    let downloadedSongIDs: Set<Song.ID>
    let usesStreamOnlyIcon: Bool
    let presentation: Presentation
    let onPlay: @MainActor (Song) -> Void
    let onSyncTrackData: @MainActor (Song) async -> Void
    let onEditMetadata: @MainActor (Song) -> Void
    let onRequestRemoval: (@MainActor (Song) -> Void)?
    /// Names the collection on screen — a folder, a playlist. Each time it
    /// changes the table scrolls itself to whatever is playing; see
    /// `Coordinator.focusCurrentSongIfNeeded`. Left `nil` to opt out.
    var focusToken: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            songs: songs,
            currentSongID: currentSongID,
            downloadedSongIDs: downloadedSongIDs,
            usesStreamOnlyIcon: usesStreamOnlyIcon,
            presentation: presentation,
            onPlay: onPlay,
            onSyncTrackData: onSyncTrackData,
            onEditMetadata: onEditMetadata,
            onRequestRemoval: onRequestRemoval
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            songs: songs,
            currentSongID: currentSongID,
            downloadedSongIDs: downloadedSongIDs,
            usesStreamOnlyIcon: usesStreamOnlyIcon,
            onPlay: onPlay,
            onSyncTrackData: onSyncTrackData,
            onEditMetadata: onEditMetadata,
            onRequestRemoval: onRequestRemoval,
            focusToken: focusToken
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource,
        NSTableViewDelegate, NSMenuItemValidation
    {
        private enum Column {
            static let trackNumber =
                NSUserInterfaceItemIdentifier("song-track-number")
            static let title = NSUserInterfaceItemIdentifier("song-title")
            static let artist = NSUserInterfaceItemIdentifier("song-artist")
            static let duration =
                NSUserInterfaceItemIdentifier("song-duration")
        }

        private var songs: [Song]
        private var currentSongID: Song.ID?
        private var downloadedSongIDs: Set<Song.ID>
        private var usesStreamOnlyIcon: Bool
        private let presentation: Presentation
        private var onPlay: @MainActor (Song) -> Void
        private var onSyncTrackData: @MainActor (Song) async -> Void
        private var onEditMetadata: @MainActor (Song) -> Void
        private var onRequestRemoval: (@MainActor (Song) -> Void)?
        private var focusToken: String?
        /// The last token this table has already scrolled to the playing song
        /// for, so each collection focuses once rather than on every update.
        private var focusedToken: String?
        private weak var tableView: NativeSongTableView?
        /// The column sort the listener has chosen, or `nil` for the order the
        /// library handed us (track order within an album, the hub's ranking within
        /// a playlist) — which is meaningful in its own right, so it stays the
        /// default rather than being replaced by an arbitrary alphabetical one.
        private var sortDescriptor: NSSortDescriptor?

        init(
            songs: [Song],
            currentSongID: Song.ID?,
            downloadedSongIDs: Set<Song.ID>,
            usesStreamOnlyIcon: Bool = false,
            presentation: Presentation,
            onPlay: @escaping @MainActor (Song) -> Void,
            onSyncTrackData:
                @escaping @MainActor (Song) async -> Void,
            onEditMetadata: @escaping @MainActor (Song) -> Void = { _ in },
            onRequestRemoval: (@MainActor (Song) -> Void)?
        ) {
            self.songs = songs
            self.currentSongID = currentSongID
            self.downloadedSongIDs = downloadedSongIDs
            self.usesStreamOnlyIcon = usesStreamOnlyIcon
            self.presentation = presentation
            self.onPlay = onPlay
            self.onSyncTrackData = onSyncTrackData
            self.onEditMetadata = onEditMetadata
            self.onRequestRemoval = onRequestRemoval
        }

        func makeScrollView() -> NSScrollView {
            let tableView = NativeSongTableView()
            self.tableView = tableView
            tableView.dataSource = self
            tableView.delegate = self
            tableView.interactionDelegate = self
            tableView.allowsEmptySelection = true
            tableView.allowsMultipleSelection = false
            tableView.allowsColumnReordering = false
            tableView.allowsColumnResizing = true
            tableView.columnAutoresizingStyle =
                .firstColumnOnlyAutoresizingStyle
            tableView.rowHeight = presentation == .album ? 34 : 28
            tableView.intercellSpacing = NSSize(
                width: 0,
                height: presentation == .album ? 1 : 0
            )
            tableView.usesAlternatingRowBackgroundColors = false
            tableView.selectionHighlightStyle = .regular
            tableView.backgroundColor = .clear
            if presentation == .album {
                tableView.gridStyleMask = .solidHorizontalGridLineMask
                tableView.gridColor = NSColor.separatorColor.withAlphaComponent(
                    0.28
                )
            }
            tableView.target = self
            tableView.doubleAction = #selector(activateDoubleClick(_:))

            if presentation.showsTrackNumber {
                let trackNumberColumn = NSTableColumn(
                    identifier: Column.trackNumber
                )
                trackNumberColumn.title = "#"
                trackNumberColumn.headerCell.alignment = .right
                trackNumberColumn.minWidth = 34
                trackNumberColumn.maxWidth = 46
                trackNumberColumn.width = 40
                trackNumberColumn.resizingMask = []
                tableView.addTableColumn(trackNumberColumn)
            }

            let titleColumn = NSTableColumn(identifier: Column.title)
            titleColumn.title = "Title"
            titleColumn.minWidth = presentation == .library ? 180 : 140
            titleColumn.width = presentation == .library ? 430 : 300
            titleColumn.resizingMask = [
                .autoresizingMask,
                .userResizingMask,
            ]
            // Prototypes only mark the columns as sortable and carry the key; the
            // actual comparison happens in `sortedSongs(_:)`, since `Song` is a Swift
            // struct and `NSSortDescriptor`'s own key-path sorting needs KVO.
            titleColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: Column.title.rawValue,
                ascending: true
            )
            tableView.addTableColumn(titleColumn)

            if presentation.showsArtist {
                let artistColumn = NSTableColumn(identifier: Column.artist)
                artistColumn.title = "Artist"
                artistColumn.minWidth = 120
                artistColumn.width = 250
                artistColumn.resizingMask = .userResizingMask
                artistColumn.sortDescriptorPrototype = NSSortDescriptor(
                    key: Column.artist.rawValue,
                    ascending: true
                )
                tableView.addTableColumn(artistColumn)
            }

            let durationColumn = NSTableColumn(identifier: Column.duration)
            durationColumn.title = "Duration"
            durationColumn.headerCell.alignment = .right
            durationColumn.minWidth = 72
            durationColumn.maxWidth = 110
            durationColumn.width = 88
            durationColumn.resizingMask = .userResizingMask
            durationColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: Column.duration.rawValue,
                ascending: true
            )
            tableView.addTableColumn(durationColumn)
            if !presentation.showsHeader {
                tableView.headerView = nil
            }

            let menu = NSMenu()
            menu.addItem(
                NSMenuItem(
                    title: "Play",
                    action: #selector(playSelected(_:)),
                    keyEquivalent: ""
                )
            )
            menu.addItem(.separator())
            menu.addItem(
                NSMenuItem(
                    title: "Sync Track Data",
                    action: #selector(syncSelected(_:)),
                    keyEquivalent: ""
                )
            )
            menu.addItem(
                NSMenuItem(
                    title: "Metadata…",
                    action: #selector(editSelectedMetadata(_:)),
                    keyEquivalent: ""
                )
            )
            if onRequestRemoval != nil {
                menu.addItem(.separator())
                menu.addItem(
                    NSMenuItem(
                        title: "Remove from Aro…",
                        action: #selector(removeSelected(_:)),
                        keyEquivalent: ""
                    )
                )
            }
            for item in menu.items where !item.isSeparatorItem {
                item.target = self
            }
            tableView.menu = menu

            let scrollView = NativeSongScrollView()
            scrollView.passesScrollEventsThrough =
                !presentation.scrollsVertically
            scrollView.documentView = tableView
            scrollView.hasVerticalScroller = presentation.scrollsVertically
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            if !presentation.scrollsVertically {
                scrollView.verticalScrollElasticity = .none
            }
            return scrollView
        }

        func update(
            songs newSongs: [Song],
            currentSongID newCurrentSongID: Song.ID?,
            downloadedSongIDs newDownloadedSongIDs: Set<Song.ID>,
            usesStreamOnlyIcon newUsesStreamOnlyIcon: Bool = false,
            onPlay: @escaping @MainActor (Song) -> Void,
            onSyncTrackData:
                @escaping @MainActor (Song) async -> Void,
            onEditMetadata: @escaping @MainActor (Song) -> Void = { _ in },
            onRequestRemoval: (@MainActor (Song) -> Void)?,
            focusToken newFocusToken: String? = nil
        ) {
            self.onPlay = onPlay
            self.onSyncTrackData = onSyncTrackData
            self.onEditMetadata = onEditMetadata
            self.onRequestRemoval = onRequestRemoval
            focusToken = newFocusToken

            guard let tableView else {
                songs = sortedSongs(newSongs)
                currentSongID = newCurrentSongID
                downloadedSongIDs = newDownloadedSongIDs
                usesStreamOnlyIcon = newUsesStreamOnlyIcon
                return
            }

            // Every path below applies the new data and then returns, so this
            // runs against a table that's already reloaded.
            defer { focusCurrentSongIfNeeded(in: tableView) }

            let oldSongs = songs
            let oldSongIDs = oldSongs.map(\.id)
            let newSongIDs = newSongs.map(\.id)
            let oldCurrentSongID = currentSongID
            let oldDownloadedSongIDs = downloadedSongIDs
            let oldUsesStreamOnlyIcon = usesStreamOnlyIcon
            if oldSongIDs != newSongIDs {
                let selectedIDs = selectedSongIDs(in: tableView)
                songs = sortedSongs(newSongs)
                currentSongID = newCurrentSongID
                downloadedSongIDs = newDownloadedSongIDs
                usesStreamOnlyIcon = newUsesStreamOnlyIcon
                tableView.reloadData()
                restoreSelection(selectedIDs, in: tableView)
                return
            }

            songs = sortedSongs(newSongs)
            currentSongID = newCurrentSongID
            downloadedSongIDs = newDownloadedSongIDs
            usesStreamOnlyIcon = newUsesStreamOnlyIcon

            if oldSongs != newSongs
                || oldUsesStreamOnlyIcon != newUsesStreamOnlyIcon {
                reloadAllCells(in: tableView)
                return
            }

            var changedTitleIDs = oldDownloadedSongIDs
                .symmetricDifference(newDownloadedSongIDs)
            if oldCurrentSongID != newCurrentSongID {
                if let oldCurrentSongID {
                    changedTitleIDs.insert(oldCurrentSongID)
                }
                if let newCurrentSongID {
                    changedTitleIDs.insert(newCurrentSongID)
                }
                reloadRows(
                    songIDs: changedTitleIDs,
                    in: tableView
                )
                return
            }
            reloadTitleCells(
                songIDs: changedTitleIDs,
                in: tableView
            )
        }

        /// Scrolls the playing track into view the first time each collection is
        /// shown, so opening Songs, a folder, or a playlist mid-listen lands on
        /// what you're hearing instead of the top of the list. Once per
        /// collection, deliberately: repeating it as playback advanced — or as a
        /// scan appended rows — would drag the table out from under anyone
        /// reading it.
        private func focusCurrentSongIfNeeded(in tableView: NSTableView) {
            guard presentation.scrollsVertically,
                  let focusToken,
                  focusToken != focusedToken,
                  // An empty table is a collection that hasn't loaded yet, not
                  // one without the playing song in it; leave the token unspent
                  // so the next update can still focus.
                  !songs.isEmpty
            else { return }
            focusedToken = focusToken

            guard currentSongID != nil else { return }
            // Row geometry and the clip view's height are both meaningless
            // until this layout pass has finished sizing the table, so the row
            // is resolved against whatever the table holds by then rather than
            // against a possibly stale index captured now.
            DispatchQueue.main.async { [weak self, weak tableView] in
                guard let self,
                      let tableView,
                      let currentSongID = self.currentSongID,
                      let row = self.songs.firstIndex(where: {
                          $0.id == currentSongID
                      })
                else { return }
                Self.centerRow(row, in: tableView)
            }
        }

        /// Centres rather than merely reveals: `scrollRowToVisible` would park
        /// the track against whichever edge it scrolled in from, hiding the
        /// surrounding album.
        private static func centerRow(_ row: Int, in tableView: NSTableView) {
            guard let scrollView = tableView.enclosingScrollView else { return }
            let clipView = scrollView.contentView
            let rowRect = tableView.rect(ofRow: row)
            guard rowRect.height > 0 else { return }
            let lowestOrigin = max(
                0,
                tableView.bounds.height - clipView.bounds.height
            )
            let origin = NSPoint(
                x: clipView.bounds.origin.x,
                y: min(
                    max(0, rowRect.midY - clipView.bounds.height / 2),
                    lowestOrigin
                )
            )
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
        }

        /// Applies the active column sort, if any. Comparisons are done here rather
        /// than by `NSSortDescriptor` itself because `Song` is a Swift value type
        /// without the KVO conformance its key-path sorting requires.
        private func sortedSongs(_ input: [Song]) -> [Song] {
            guard let sortDescriptor, let key = sortDescriptor.key else { return input }
            let ascending = sortDescriptor.ascending

            /// `localizedStandardCompare` so ordering matches Finder: case- and
            /// diacritic-insensitive, and "Track 10" sorts after "Track 9" rather
            /// than between "Track 1" and "Track 2".
            func byText(_ lhs: String, _ rhs: String) -> Bool? {
                switch lhs.localizedStandardCompare(rhs) {
                case .orderedAscending: return ascending
                case .orderedDescending: return !ascending
                case .orderedSame: return nil
                }
            }

            switch key {
            case Column.title.rawValue:
                return input.sorted { byText($0.title, $1.title) ?? false }
            case Column.artist.rawValue:
                return input.sorted { lhs, rhs in
                    // Ties fall back to title, always ascending — within one artist
                    // an alphabetical run reads far better than arbitrary order.
                    byText(lhs.artist, rhs.artist)
                        ?? (lhs.title.localizedStandardCompare(rhs.title)
                            == .orderedAscending)
                }
            case Column.duration.rawValue:
                return input.sorted { lhs, rhs in
                    let left = lhs.duration ?? 0
                    let right = rhs.duration ?? 0
                    if left == right {
                        return lhs.title.localizedStandardCompare(rhs.title)
                            == .orderedAscending
                    }
                    return ascending ? left < right : left > right
                }
            default:
                return input
            }
        }

        func tableView(
            _ tableView: NSTableView,
            sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            sortDescriptor = tableView.sortDescriptors.first
            songs = sortedSongs(songs)
            tableView.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            songs.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard songs.indices.contains(row), let tableColumn else {
                return nil
            }
            let song = songs[row]
            switch tableColumn.identifier {
            case Column.trackNumber:
                let cell = trackNumberCell(in: tableView)
                cell.configure(
                    number: row + 1,
                    isCurrent: currentSongID == song.id
                )
                return cell
            case Column.title:
                let cell = titleCell(in: tableView)
                cell.configure(
                    song: song,
                    isCurrent: currentSongID == song.id,
                    isDownloaded: downloadedSongIDs.contains(song.id),
                    usesStreamOnlyIcon: usesStreamOnlyIcon,
                    showsDownloadStatus:
                        presentation.showsDownloadStatus,
                    showsPlayingIndicator: presentation != .album
                )
                return cell
            case Column.artist:
                return textCell(
                    in: tableView,
                    identifier: Column.artist,
                    text: song.artist,
                    alignment: .left,
                    monospacedDigits: false
                )
            case Column.duration:
                return textCell(
                    in: tableView,
                    identifier: Column.duration,
                    text: song.formattedDuration,
                    alignment: .right,
                    monospacedDigits: true,
                    textColor: currentSongID == song.id
                        ? AroTheme.violetNSColor
                        : .secondaryLabelColor
                )
            default:
                return nil
            }
        }

        @objc private func activateDoubleClick(_ sender: Any?) {
            guard let tableView else { return }
            activate(row: tableView.clickedRow)
        }

        @objc private func playSelected(_ sender: Any?) {
            guard let tableView else { return }
            activate(row: tableView.selectedRow)
        }

        @objc private func syncSelected(_ sender: Any?) {
            guard let song = selectedSong else { return }
            Task { @MainActor [onSyncTrackData] in
                await onSyncTrackData(song)
            }
        }

        @objc private func removeSelected(_ sender: Any?) {
            guard let song = selectedSong, let onRequestRemoval else {
                return
            }
            onRequestRemoval(song)
        }

        @objc private func editSelectedMetadata(_ sender: Any?) {
            guard let song = selectedSong else { return }
            onEditMetadata(song)
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            selectedSong != nil
        }

        func tableView(
            _ tableView: NSTableView,
            rowViewForRow row: Int
        ) -> NSTableRowView? {
            let rowView = CurrentSongTableRowView()
            if songs.indices.contains(row) {
                rowView.isCurrentSong =
                    songs[row].id == currentSongID
            }
            return rowView
        }

        func activate(row: Int) {
            guard songs.indices.contains(row), let tableView else {
                return
            }
            tableView.selectRowIndexes(
                IndexSet(integer: row),
                byExtendingSelection: false
            )
            onPlay(songs[row])
        }

        private var selectedSong: Song? {
            guard let tableView,
                  songs.indices.contains(tableView.selectedRow) else {
                return nil
            }
            return songs[tableView.selectedRow]
        }

        private func selectedSongIDs(
            in tableView: NSTableView
        ) -> Set<Song.ID> {
            Set(
                tableView.selectedRowIndexes.compactMap { row in
                    songs.indices.contains(row) ? songs[row].id : nil
                }
            )
        }

        private func restoreSelection(
            _ selectedIDs: Set<Song.ID>,
            in tableView: NSTableView
        ) {
            let rows = IndexSet(
                songs.indices.filter { selectedIDs.contains(songs[$0].id) }
            )
            tableView.selectRowIndexes(
                rows,
                byExtendingSelection: false
            )
        }

        private func reloadAllCells(in tableView: NSTableView) {
            guard !songs.isEmpty else { return }
            tableView.reloadData(
                forRowIndexes: IndexSet(integersIn: songs.indices),
                columnIndexes: IndexSet(
                    integersIn: 0..<tableView.numberOfColumns
                )
            )
        }

        private func reloadTitleCells(
            songIDs: Set<Song.ID>,
            in tableView: NSTableView
        ) {
            let rows = IndexSet(
                songs.indices.filter { songIDs.contains(songs[$0].id) }
            )
            let titleColumn = tableView.column(
                withIdentifier: Column.title
            )
            guard !rows.isEmpty, titleColumn >= 0 else { return }
            tableView.reloadData(
                forRowIndexes: rows,
                columnIndexes: IndexSet(integer: titleColumn)
            )
        }

        private func reloadRows(
            songIDs: Set<Song.ID>,
            in tableView: NSTableView
        ) {
            let rows = IndexSet(
                songs.indices.filter { songIDs.contains(songs[$0].id) }
            )
            guard !rows.isEmpty else { return }
            tableView.reloadData(
                forRowIndexes: rows,
                columnIndexes: IndexSet(
                    integersIn: 0..<tableView.numberOfColumns
                )
            )
            for row in rows {
                (tableView.rowView(
                    atRow: row,
                    makeIfNecessary: false
                ) as? CurrentSongTableRowView)?.isCurrentSong =
                    songs[row].id == currentSongID
            }
        }

        private func titleCell(
            in tableView: NSTableView
        ) -> SongTitleTableCellView {
            if let cell = tableView.makeView(
                withIdentifier: Column.title,
                owner: self
            ) as? SongTitleTableCellView {
                return cell
            }
            let cell = SongTitleTableCellView()
            cell.identifier = Column.title
            return cell
        }

        private func trackNumberCell(
            in tableView: NSTableView
        ) -> TrackNumberTableCellView {
            if let cell = tableView.makeView(
                withIdentifier: Column.trackNumber,
                owner: self
            ) as? TrackNumberTableCellView {
                return cell
            }
            let cell = TrackNumberTableCellView()
            cell.identifier = Column.trackNumber
            return cell
        }

        private func textCell(
            in tableView: NSTableView,
            identifier: NSUserInterfaceItemIdentifier,
            text: String,
            alignment: NSTextAlignment,
            monospacedDigits: Bool,
            textColor: NSColor = .labelColor
        ) -> NSTableCellView {
            let cell: NSTableCellView
            if let reused = tableView.makeView(
                withIdentifier: identifier,
                owner: self
            ) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingTail
                cell.textField = label
                cell.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(
                        equalTo: cell.leadingAnchor,
                        constant: 4
                    ),
                    label.trailingAnchor.constraint(
                        equalTo: cell.trailingAnchor,
                        constant: -4
                    ),
                    label.centerYAnchor.constraint(
                        equalTo: cell.centerYAnchor
                    ),
                ])
            }
            cell.textField?.stringValue = text
            cell.textField?.alignment = alignment
            cell.textField?.font = monospacedDigits
                ? .monospacedDigitSystemFont(
                    ofSize: NSFont.systemFontSize,
                    weight: .regular
                )
                : .systemFont(ofSize: NSFont.systemFontSize)
            cell.textField?.textColor = textColor
            return cell
        }
    }
}

@MainActor
private protocol NativeSongTableInteractionDelegate: AnyObject {
    func activate(row: Int)
}

private final class NativeSongTableView: NSTableView {
    weak var interactionDelegate:
        (any NativeSongTableInteractionDelegate)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: location)
        guard clickedRow >= 0 else {
            return nil
        }
        if selectedRow != clickedRow {
            selectRowIndexes(
                IndexSet(integer: clickedRow),
                byExtendingSelection: false
            )
        }
        return menu
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            interactionDelegate?.activate(row: selectedRow)
            return
        }
        super.keyDown(with: event)
    }
}

private final class NativeSongScrollView: NSScrollView {
    var passesScrollEventsThrough = false

    override func scrollWheel(with event: NSEvent) {
        guard passesScrollEventsThrough else {
            super.scrollWheel(with: event)
            return
        }
        nextResponder?.scrollWheel(with: event)
    }
}

extension AppKitSongTable.Coordinator:
    NativeSongTableInteractionDelegate {}

private final class SongTitleTableCellView: NSTableCellView {
    private let playingImage = NSImageView()
    private let downloadImage = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var downloadLeadingConstraint: NSLayoutConstraint!
    private var downloadWidthConstraint: NSLayoutConstraint!
    private var titleLeadingConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        playingImage.translatesAutoresizingMaskIntoConstraints = false
        playingImage.imageScaling = .scaleProportionallyDown
        playingImage.contentTintColor = AroTheme.violetNSColor

        downloadImage.translatesAutoresizingMaskIntoConstraints = false
        downloadImage.imageScaling = .scaleProportionallyDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        textField = titleLabel

        addSubview(playingImage)
        addSubview(downloadImage)
        addSubview(titleLabel)

        downloadLeadingConstraint = downloadImage.leadingAnchor.constraint(
            equalTo: playingImage.trailingAnchor,
            constant: 6
        )
        downloadWidthConstraint = downloadImage.widthAnchor.constraint(
            equalToConstant: 16
        )
        titleLeadingConstraint = titleLabel.leadingAnchor.constraint(
            equalTo: downloadImage.trailingAnchor,
            constant: 6
        )

        NSLayoutConstraint.activate([
            playingImage.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 4
            ),
            playingImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            playingImage.widthAnchor.constraint(equalToConstant: 16),
            playingImage.heightAnchor.constraint(equalToConstant: 16),

            downloadLeadingConstraint,
            downloadImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            downloadWidthConstraint,
            downloadImage.heightAnchor.constraint(equalToConstant: 16),

            titleLeadingConstraint,
            titleLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -4
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        song: Song,
        isCurrent: Bool,
        isDownloaded: Bool,
        usesStreamOnlyIcon: Bool,
        showsDownloadStatus: Bool,
        showsPlayingIndicator: Bool
    ) {
        titleLabel.stringValue = song.title

        playingImage.image = NSImage(
            systemSymbolName: "speaker.wave.2.fill",
            accessibilityDescription: "Currently playing"
        )
        let displaysPlaying = isCurrent && showsPlayingIndicator
        playingImage.isHidden = !displaysPlaying
        playingImage.setAccessibilityElement(displaysPlaying)
        playingImage.setAccessibilityLabel("Currently playing")

        downloadImage.isHidden = !showsDownloadStatus
        downloadLeadingConstraint.constant =
            showsDownloadStatus ? 6 : 0
        downloadWidthConstraint.constant =
            showsDownloadStatus ? 16 : 0
        titleLeadingConstraint.constant = 6
        downloadImage.setAccessibilityElement(showsDownloadStatus)

        guard showsDownloadStatus else {
            downloadImage.image = nil
            downloadImage.toolTip = nil
            return
        }

        let downloadSymbol = usesStreamOnlyIcon
            ? "dot.radiowaves.left.and.right"
            : isDownloaded ? "icloud.fill" : "icloud.slash"
        let downloadDescription = usesStreamOnlyIcon
            ? "Stream only"
            : isDownloaded ? "Downloaded" : "Not downloaded"
        downloadImage.image = NSImage(
            systemSymbolName: downloadSymbol,
            accessibilityDescription: downloadDescription
        )
        downloadImage.contentTintColor = usesStreamOnlyIcon
            ? AroTheme.violetNSColor
            : isDownloaded
            ? .systemGreen
            : .secondaryLabelColor
        downloadImage.toolTip = usesStreamOnlyIcon
            ? "Streams from your library server and is never retained"
            : isDownloaded
            ? "Downloaded — available offline"
            : "Streams from your library server — not stored on this Mac"
        downloadImage.setAccessibilityLabel(downloadDescription)
    }
}

private final class TrackNumberTableCellView: NSTableCellView {
    private let numberLabel = NSTextField(labelWithString: "")
    private let playingImage = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.alignment = .right
        numberLabel.font = .monospacedDigitSystemFont(
            ofSize: 12,
            weight: .regular
        )
        numberLabel.textColor = .secondaryLabelColor

        playingImage.translatesAutoresizingMaskIntoConstraints = false
        playingImage.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Currently playing"
        )
        playingImage.imageScaling = .scaleProportionallyDown
        playingImage.contentTintColor = AroTheme.violetNSColor

        addSubview(numberLabel)
        addSubview(playingImage)
        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            numberLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -5
            ),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            playingImage.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -5
            ),
            playingImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            playingImage.widthAnchor.constraint(equalToConstant: 15),
            playingImage.heightAnchor.constraint(equalToConstant: 15),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(number: Int, isCurrent: Bool) {
        numberLabel.stringValue = String(number)
        numberLabel.isHidden = isCurrent
        playingImage.isHidden = !isCurrent
        playingImage.setAccessibilityElement(isCurrent)
        playingImage.setAccessibilityLabel("Currently playing")
    }
}

private final class CurrentSongTableRowView: NSTableRowView {
    var isCurrentSong = false {
        didSet {
            needsDisplay = true
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isCurrentSong, !isSelected else { return }
        AroTheme.violetNSColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 2, dy: 1),
            xRadius: 6,
            yRadius: 6
        ).fill()
    }

    /// `.regular` selection style otherwise fills with
    /// `.selectedContentBackgroundColor`, which tracks the user's system-wide
    /// accent color (blue by default) rather than Aro's purple identity.
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let fillColor = isEmphasized
            ? AroTheme.violetNSColor.withAlphaComponent(0.28)
            : AroTheme.violetNSColor.withAlphaComponent(0.16)
        fillColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 2, dy: 1),
            xRadius: 6,
            yRadius: 6
        ).fill()
    }
}
