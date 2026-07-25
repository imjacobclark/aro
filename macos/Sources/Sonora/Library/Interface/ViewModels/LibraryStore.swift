import Foundation
import SonoraCommon
import Observation

@MainActor
@Observable
final class LibraryStore {
    var selection: Destination? = .songs
    private(set) var folders: [WatchedFolder] = []
    private(set) var songsByFolder: [UUID: [Song]] = [:]
    private(set) var scanStates: [UUID: FolderScanState] = [:]

    @ObservationIgnored private let scanFolder: ScanWatchedFolder
    @ObservationIgnored private let analyzeSongLoudness: AnalyzeSongLoudness
    @ObservationIgnored private let manageFolders: ManageWatchedFolders
    @ObservationIgnored private let monitorFactory: any FolderMonitorCreating
    @ObservationIgnored private let folderAccess: any FolderAccessing
    @ObservationIgnored private let legacyFolders:
        any LegacyWatchedFolderStoring
    @ObservationIgnored private var scanTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var analysisTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rescanTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var monitors: [
        UUID: any FolderMonitoring
    ] = [:]
    @ObservationIgnored private var hasStarted = false

    init(
        scanFolder: ScanWatchedFolder,
        analyzeSongLoudness: AnalyzeSongLoudness,
        manageFolders: ManageWatchedFolders,
        monitorFactory: any FolderMonitorCreating,
        folderAccess: any FolderAccessing,
        legacyFolders: any LegacyWatchedFolderStoring
    ) {
        self.scanFolder = scanFolder
        self.analyzeSongLoudness = analyzeSongLoudness
        self.manageFolders = manageFolders
        self.monitorFactory = monitorFactory
        self.folderAccess = folderAccess
        self.legacyFolders = legacyFolders
        restoreFolders()
    }

    var visibleSongs: [Song] {
        switch selection {
        case .folder(let id):
            return songsByFolder[id] ?? []
        case .songs, .artists, .albums, .stats, .libraryHealth, .none:
            return SongLibrary.aggregate(songsByFolder)
        }
    }

    var allSongs: [Song] {
        SongLibrary.aggregate(songsByFolder)
    }

    func songsExcludingFolder(id: UUID) -> [Song] {
        SongLibrary.aggregate(
            songsByFolder.filter { $0.key != id }
        )
    }

    var selectedTitle: String {
        switch selection {
        case .folder(let id):
            return folders.first(where: { $0.id == id })?.displayName ?? "Songs"
        case .stats:
            return "Stats"
        case .artists:
            return "Artists"
        case .albums:
            return "Albums"
        case .libraryHealth:
            return "Library Health"
        case .songs, .none:
            return "Songs"
        }
    }

    var selectedScanState: FolderScanState {
        switch selection {
        case .folder(let id):
            return scanStates[id] ?? .idle
        case .songs, .artists, .albums, .stats, .libraryHealth, .none:
            if scanStates.values.contains(.scanning) {
                return .scanning
            }

            let warningCount = scanStates.values.filter {
                if case .warning = $0 {
                    return true
                }
                return false
            }.count

            return warningCount > 0
                ? .warning("\(warningCount) watched folder(s) could not be fully scanned.")
                : .idle
        }
    }

    func start() {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        for folder in folders {
            startMonitoring(folder)
            scan(folderID: folder.id)
        }
    }

    func addFolder(_ selectedURL: URL) {
        let url = folderAccess.normalizedURL(selectedURL)

        if let existing = folders.first(where: { $0.url.path == url.path }) {
            selection = .folder(existing.id)
            return
        }

        let bookmarkData = folderAccess.bookmarkData(for: url)
        let didStartSecurityScope = folderAccess.beginAccessing(url)
        let folder = WatchedFolder(
            id: UUID(),
            url: url,
            displayName: url.lastPathComponent,
            bookmarkData: bookmarkData,
            isAccessible: folderAccess.isAccessibleDirectory(url),
            didStartSecurityScope: didStartSecurityScope
        )

        folders.append(folder)
        folders.sort {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        scanStates[folder.id] = folder.isAccessible
            ? .idle
            : .warning("This folder is unavailable.")
        persistFolders()
        selection = .folder(folder.id)

        guard folder.isAccessible else {
            return
        }

        startMonitoring(folder)
        scan(folderID: folder.id)
    }

    func removeFolder(id: UUID) {
        scanTasks[id]?.cancel()
        analysisTasks[id]?.cancel()
        rescanTasks[id]?.cancel()
        monitors[id]?.stop()

        if let folder = folders.first(where: { $0.id == id }),
           folder.didStartSecurityScope {
            folderAccess.endAccessing(folder.url)
        }

        scanTasks[id] = nil
        analysisTasks[id] = nil
        rescanTasks[id] = nil
        monitors[id] = nil
        songsByFolder[id] = nil
        scanStates[id] = nil
        folders.removeAll { $0.id == id }
        manageFolders.remove(folderID: id)

        if selection == .folder(id) {
            selection = .songs
        }

        persistFolders()
    }

    func scan(folderID: UUID) {
        guard let folder = folders.first(where: { $0.id == folderID }) else {
            return
        }

        guard folderAccess.isAccessibleDirectory(folder.url) else {
            updateAccessibility(for: folderID, isAccessible: false)
            manageFolders.markUnavailable(folderID: folderID)
            songsByFolder[folderID] = []
            scanStates[folderID] = .warning("This folder is unavailable.")
            return
        }

        updateAccessibility(for: folderID, isAccessible: true)
        scanTasks[folderID]?.cancel()
        scanStates[folderID] = .scanning

        let scanFolder = scanFolder
        let url = folder.url
        scanTasks[folderID] = Task { [weak self] in
            let result = await scanFolder.execute(
                folderID: folderID,
                url: url
            )
            guard !Task.isCancelled else {
                return
            }

            guard let self else {
                return
            }
            self.songsByFolder[folderID] = result.songs
            self.scanStates[folderID] = result.skippedFileCount > 0
                ? .warning("\(result.skippedFileCount) audio file(s) could not be read.")
                : .idle
            self.scanTasks[folderID] = nil
            self.scheduleLoudnessAnalysis(
                songs: result.songs,
                folderID: folderID
            )
        }
    }

    private func scheduleLoudnessAnalysis(
        songs: [Song],
        folderID: UUID
    ) {
        analysisTasks[folderID]?.cancel()
        let analyzeSongLoudness = analyzeSongLoudness
        analysisTasks[folderID] = Task { [weak self] in
            for song in songs where !Task.isCancelled {
                guard let analysis = await analyzeSongLoudness.execute(
                    song: song
                ),
                      !Task.isCancelled else {
                    continue
                }

                guard var folderSongs = self?.songsByFolder[folderID],
                      let index = folderSongs.firstIndex(where: {
                          $0.id == song.id
                      }) else {
                    continue
                }
                folderSongs[index].loudness = analysis
                self?.songsByFolder[folderID] = folderSongs
            }
            self?.analysisTasks[folderID] = nil
        }
    }

    private func scheduleRescan(folderID: UUID) {
        rescanTasks[folderID]?.cancel()
        rescanTasks[folderID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else {
                return
            }

            self?.scan(folderID: folderID)
            self?.rescanTasks[folderID] = nil
        }
    }

    private func startMonitoring(_ folder: WatchedFolder) {
        monitors[folder.id]?.stop()
        monitors[folder.id] = monitorFactory.makeMonitor(
            for: folder.url
        ) { [weak self] in
            Task { @MainActor in
                self?.scheduleRescan(folderID: folder.id)
            }
        }
    }

    private func restoreFolders() {
        let databaseRecords = manageFolders.storedFolders()
        let records: [StoredWatchedFolder]
        if !databaseRecords.isEmpty {
            records = databaseRecords
        } else {
            records = legacyFolders.load()
        }

        folders = records.map { record in
            let access = folderAccess.resolve(
                path: record.path,
                bookmarkData: record.bookmarkData
            )

            return WatchedFolder(
                id: record.id,
                url: access.url,
                displayName: record.displayName,
                bookmarkData: access.bookmarkData,
                isAccessible: folderAccess.isAccessibleDirectory(
                    access.url
                ),
                didStartSecurityScope: access.didStartSecurityScope
            )
        }
        .sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        for folder in folders {
            scanStates[folder.id] = folder.isAccessible
                ? .idle
                : .warning("This folder is unavailable.")
            songsByFolder[folder.id] = manageFolders.storedSongs(
                folderID: folder.id
            )
        }

        if records.count != folders.count
            || folders.contains(where: { $0.bookmarkData != nil }) {
            persistFolders()
        } else {
            for folder in folders {
                manageFolders.save(folder)
            }
        }
    }

    private func persistFolders() {
        for folder in folders {
            manageFolders.save(folder)
        }

        let records = folders.map {
            StoredWatchedFolder(
                id: $0.id,
                displayName: $0.displayName,
                path: $0.url.path,
                bookmarkData: $0.bookmarkData
            )
        }

        legacyFolders.save(records)
    }

    private func updateAccessibility(for id: UUID, isAccessible: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else {
            return
        }

        folders[index].isAccessible = isAccessible
    }

}
