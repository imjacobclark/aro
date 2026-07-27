import Foundation
import Observation
import AroCommon

@MainActor
@Observable
final class LibraryRuntime {
    let database: LibraryDatabase
    let libraryStore: LibraryStore
    let playbackController: PlaybackController
    let mediaCacheController: MediaCacheController
    let reviewLibraryHealth: ReviewLibraryHealth
    let loadStatsDashboard: LoadStatsDashboard
    let libraryFileManager: any LibraryFileManaging
    let syncOperationStore: SQLiteSyncOperationStore
    private let trackStateRepository: SQLiteTrackStateRepository

    init(
        databaseURL: URL,
        playbackPreferences: PlaybackPreferences,
        audioDeviceManager: AudioDeviceManager,
        mediaDirectory: URL? = nil,
        profile: LibraryProfile? = nil
    ) {
        let database = LibraryDatabase(url: databaseURL)
        self.database = database
        let operationStore = SQLiteSyncOperationStore(database: database)
        syncOperationStore = operationStore
        trackStateRepository = SQLiteTrackStateRepository(database: database)

        let loudnessRepository = SQLiteLoudnessAnalysisRepository(
            database: database
        )
        let loudnessService = LoudnessAnalysisService(
            repository: loudnessRepository
        )
        let cacheDirectory = mediaDirectory ?? FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Aro/Media", isDirectory: true)
        let remoteCredential = profile?.hubID.flatMap { hubID in
            try? FileHubCredentialStore().load(
                hubID: hubID,
                deviceID: database.deviceID
            )
        }
        let remoteTLSFingerprint = profile?.baseURL.flatMap {
            operationStore.membership(baseURL: $0)?.tlsFingerprint
        }
        let prepareSong = PrepareSongForPlayback(
            downloader: URLSessionMediaDownloader(
                cacheDirectory: cacheDirectory,
                credential: remoteCredential,
                pinnedTLSFingerprint: remoteTLSFingerprint
            ),
            verifier: CachingSHA256MediaVerifier(
                cache: SQLiteMediaCache(database: database)
            )
        )
        mediaCacheController = MediaCacheController(
            database: database,
            prepare: prepareSong
        )
        libraryFileManager = SQLiteLibraryFileManager(database: database)
        let libraryCatalog = SQLiteLibraryCatalogRepository(
            database: database,
            loudness: loudnessRepository
        )
        reviewLibraryHealth = ReviewLibraryHealth(
            tracks: SQLiteLibraryHealthTrackQuery(database: database)
        )
        loadStatsDashboard = LoadStatsDashboard(
            stats: SQLiteStatsQuery(database: database)
        )
        libraryStore = LibraryStore(
            scanFolder: ScanWatchedFolder(
                scanner: AudioScanner(
                    contentHashCache: SQLiteContentHashCache(
                        database: database
                    )
                ),
                catalog: libraryCatalog
            ),
            analyzeSongLoudness: AnalyzeSongLoudness(
                analyzer: loudnessService
            ),
            manageFolders: ManageWatchedFolders(catalog: libraryCatalog),
            monitorFactory: FSEventsFolderMonitorFactory(),
            folderAccess: SecurityScopedFolderAccess(),
            legacyFolders: InMemoryLegacyWatchedFolderStore()
        )
        playbackController = PlaybackController(
            preferences: playbackPreferences,
            loudnessService: loudnessService,
            listeningHistory: SQLiteListeningHistoryRecorder(
                database: database
            ),
            effectiveModeResolver: {
                PlaybackRoutePolicy().effectiveMode(
                    preferredMode: playbackPreferences.mode,
                    device: audioDeviceManager.selectedDevice(
                        for: playbackPreferences.outputDeviceUID
                    )
                )
            },
            prepareSong: prepareSong,
            mediaLocationResolver: { song in
                guard !song.url.isFileURL,
                      let hash = song.fileFingerprint?.contentHash,
                      let byteCount = song.fileSizeBytes else {
                    return nil
                }
                return .remote(
                    RemoteMedia(
                        trackID: song.libraryID,
                        contentHash: hash,
                        byteCount: byteCount,
                        downloadURL: song.url
                    )
                )
            },
            engineFactory: {
                HighResolutionPlaybackEngine(
                    preferences: playbackPreferences,
                    deviceManager: audioDeviceManager
                )
            }
        )
    }

    func removeFromLibrary(trackID: UUID) throws {
        try trackStateRepository.tombstone(trackID: trackID)
        libraryStore.reloadStoredLibrary()
    }
}
