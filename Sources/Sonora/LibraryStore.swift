import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
    private struct PersistedFolder: Codable {
        let id: UUID
        let displayName: String
        let path: String
        let bookmarkData: Data?
    }

    private static let persistenceKey = "watchedFolders.v1"

    var selection: Destination? = .songs
    private(set) var folders: [WatchedFolder] = []
    private(set) var songsByFolder: [UUID: [Song]] = [:]
    private(set) var scanStates: [UUID: FolderScanState] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let scanner: AudioScanner
    @ObservationIgnored private let loudnessService: LoudnessAnalysisService
    @ObservationIgnored private let database: LibraryDatabase
    @ObservationIgnored private var scanTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var analysisTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rescanTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var monitors: [UUID: FolderMonitor] = [:]
    @ObservationIgnored private var hasStarted = false

    init(
        defaults: UserDefaults = .standard,
        scanner: AudioScanner = AudioScanner(),
        loudnessService: LoudnessAnalysisService = LoudnessAnalysisService(),
        database: LibraryDatabase = .shared
    ) {
        self.defaults = defaults
        self.scanner = scanner
        self.loudnessService = loudnessService
        self.database = database
        restoreFolders()
    }

    var visibleSongs: [Song] {
        switch selection {
        case .folder(let id):
            return songsByFolder[id] ?? []
        case .songs, .stats, .libraryHealth, .none:
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
        case .songs, .stats, .libraryHealth, .none:
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
        let url = selectedURL
            .resolvingSymlinksInPath()
            .standardizedFileURL

        if let existing = folders.first(where: { $0.url.path == url.path }) {
            selection = .folder(existing.id)
            return
        }

        let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let didStartSecurityScope = url.startAccessingSecurityScopedResource()
        let folder = WatchedFolder(
            id: UUID(),
            url: url,
            displayName: url.lastPathComponent,
            bookmarkData: bookmarkData,
            isAccessible: isAccessibleDirectory(url),
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
            folder.url.stopAccessingSecurityScopedResource()
        }

        scanTasks[id] = nil
        analysisTasks[id] = nil
        rescanTasks[id] = nil
        monitors[id] = nil
        songsByFolder[id] = nil
        scanStates[id] = nil
        folders.removeAll { $0.id == id }
        database.removeFolder(id: id)

        if selection == .folder(id) {
            selection = .songs
        }

        persistFolders()
    }

    func scan(folderID: UUID) {
        guard let folder = folders.first(where: { $0.id == folderID }) else {
            return
        }

        guard isAccessibleDirectory(folder.url) else {
            updateAccessibility(for: folderID, isAccessible: false)
            database.markFolderUnavailable(id: folderID)
            songsByFolder[folderID] = []
            scanStates[folderID] = .warning("This folder is unavailable.")
            return
        }

        updateAccessibility(for: folderID, isAccessible: true)
        scanTasks[folderID]?.cancel()
        scanStates[folderID] = .scanning

        let scanner = scanner
        let url = folder.url
        scanTasks[folderID] = Task { [weak self] in
            let result = await scanner.scan(folder: url)
            guard !Task.isCancelled else {
                return
            }

            guard let self else {
                return
            }
            let reconciledSongs = self.database.reconcile(
                songs: result.songs,
                folderID: folderID
            )
            self.songsByFolder[folderID] = reconciledSongs
            self.scanStates[folderID] = result.skippedFileCount > 0
                ? .warning("\(result.skippedFileCount) audio file(s) could not be read.")
                : .idle
            self.scanTasks[folderID] = nil
            self.scheduleLoudnessAnalysis(
                songs: reconciledSongs,
                folderID: folderID
            )
        }
    }

    private func scheduleLoudnessAnalysis(
        songs: [Song],
        folderID: UUID
    ) {
        analysisTasks[folderID]?.cancel()
        let service = loudnessService
        analysisTasks[folderID] = Task { [weak self] in
            for song in songs where !Task.isCancelled {
                guard let analysis = await service.analysis(for: song),
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
        monitors[folder.id] = FolderMonitor(url: folder.url) { [weak self] in
            Task { @MainActor in
                self?.scheduleRescan(folderID: folder.id)
            }
        }
    }

    private func restoreFolders() {
        let databaseRecords = database.watchedFolders()
        let records: [PersistedFolder]
        if !databaseRecords.isEmpty {
            records = databaseRecords.map {
                PersistedFolder(
                    id: $0.id,
                    displayName: $0.displayName,
                    path: $0.path,
                    bookmarkData: $0.bookmarkData
                )
            }
        } else if let data = defaults.data(forKey: Self.persistenceKey),
                  let legacyRecords = try? JSONDecoder().decode(
                      [PersistedFolder].self,
                      from: data
                  ) {
            records = legacyRecords
        } else {
            records = []
        }

        folders = records.map { record in
            var bookmarkIsStale = false
            let bookmarkedURL = record.bookmarkData.flatMap {
                try? URL(
                    resolvingBookmarkData: $0,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &bookmarkIsStale
                )
            }
            let url = (bookmarkedURL ?? URL(fileURLWithPath: record.path))
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let didStartSecurityScope = url.startAccessingSecurityScopedResource()
            let refreshedBookmark = bookmarkIsStale
                ? try? url.bookmarkData(options: [.withSecurityScope])
                : record.bookmarkData

            return WatchedFolder(
                id: record.id,
                url: url,
                displayName: record.displayName,
                bookmarkData: refreshedBookmark,
                isAccessible: isAccessibleDirectory(url),
                didStartSecurityScope: didStartSecurityScope
            )
        }
        .sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        for folder in folders {
            scanStates[folder.id] = folder.isAccessible
                ? .idle
                : .warning("This folder is unavailable.")
            songsByFolder[folder.id] = database.songs(folderID: folder.id)
        }

        if records.count != folders.count
            || folders.contains(where: { $0.bookmarkData != nil }) {
            persistFolders()
        } else {
            for folder in folders {
                database.save(folder: folder)
            }
        }
    }

    private func persistFolders() {
        for folder in folders {
            database.save(folder: folder)
        }

        let records = folders.map {
            PersistedFolder(
                id: $0.id,
                displayName: $0.displayName,
                path: $0.url.path,
                bookmarkData: $0.bookmarkData
            )
        }

        guard let data = try? JSONEncoder().encode(records) else {
            return
        }

        defaults.set(data, forKey: Self.persistenceKey)
    }

    private func updateAccessibility(for id: UUID, isAccessible: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else {
            return
        }

        folders[index].isAccessible = isAccessible
    }

    private func isAccessibleDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue && FileManager.default.isReadableFile(atPath: url.path)
    }
}
