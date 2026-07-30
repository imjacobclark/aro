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
    private let offlinePolicy: OfflineDownloadPolicy
    private let storageLimitBytes: Int64?

    init(
        databaseURL: URL,
        playbackPreferences: PlaybackPreferences,
        audioDeviceManager: AudioDeviceManager,
        mediaDirectory: URL? = nil,
        profile: LibraryProfile? = nil
    ) {
        let database = LibraryDatabase(url: databaseURL)
        self.database = database
        offlinePolicy = profile?.offlinePolicy ?? .stream
        storageLimitBytes = profile?.storageLimitBytes
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
        let mediaCache = SQLiteMediaCache(database: database)
        let storagePolicyState = MediaStoragePolicyState(
            profile?.offlinePolicy ?? .stream
        )
        let prepareSong = PrepareSongForPlayback(
            downloader: URLSessionMediaDownloader(
                cacheDirectory: cacheDirectory,
                credential: remoteCredential,
                pinnedTLSFingerprint: remoteTLSFingerprint
            ),
            verifier: CachingSHA256MediaVerifier(
                cache: mediaCache,
                shouldCache: { hash in
                    mediaCache.shouldRetainStreamedMedia(
                        hash: hash,
                        policy: storagePolicyState.policy
                    )
                }
            )
        )
        let streamingCoordinator = ProgressiveMediaCoordinator(
            cacheDirectory: cacheDirectory,
            credential: remoteCredential,
            pinnedTLSFingerprint: remoteTLSFingerprint,
            shouldRetain: { media in
                mediaCache.shouldRetainStreamedMedia(
                    hash: media.contentHash,
                    policy: storagePolicyState.policy
                )
            }
        ) { hash, url, byteCount in
            mediaCache.register(
                hash: hash,
                localURL: url,
                byteCount: byteCount
            )
        }
        mediaCacheController = MediaCacheController(
            database: database,
            prepare: prepareSong,
            cacheDirectory: cacheDirectory,
            storagePolicyState: storagePolicyState
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
            nowPlayingPublisher: MPNowPlayingPublisher(),
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
                if storagePolicyState.policy != .streamOnly,
                   let hash = song.contentHash,
                   let cachedURL = mediaCache.localURL(hash: hash) {
                    return .local(cachedURL)
                }
                guard !song.url.isFileURL,
                      let hash = song.contentHash,
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
            progressivePlaybackEligibility: { song in
                switch song.audioProperties?.codec.lowercased() {
                case "flac", "ogg", "oga", "vorbis", "ogg vorbis",
                     "mp3", "mpeg", "mpeg-1 layer 3", "m4a", "mp4",
                     "aac", "alac", "apple lossless", "wav", "wave",
                     "aif", "aiff":
                    true
                default:
                    false
                }
            },
            progressiveDownloadFallbackAllowed: {
                storagePolicyState.policy != .streamOnly
            },
            engineFactory: {
                HighResolutionPlaybackEngine(
                    preferences: playbackPreferences,
                    deviceManager: audioDeviceManager,
                    streamingCoordinator: streamingCoordinator
                )
            }
        )
    }

    func removeFromLibrary(trackID: UUID) throws {
        try trackStateRepository.tombstone(trackID: trackID)
        libraryStore.reloadStoredLibrary()
    }

    func setFavourite(trackID: UUID, favourite: Bool) async throws {
        try trackStateRepository.setFavourite(
            trackID: trackID,
            favourite: favourite
        )
        libraryStore.reloadStoredLibrary()
        playbackController.reconcileAvailableSongs(libraryStore.allSongs)
        await mediaCacheController.apply(
            offlinePolicy,
            storageLimitBytes: storageLimitBytes
        )
    }
}
