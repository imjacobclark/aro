import CryptoKit
import Foundation
import AroCommon
import OSLog

enum ProgressiveMediaError: LocalizedError, Sendable {
    case invalidResponse
    case incompleteRange
    case integrityMismatch
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The library returned an invalid streaming response."
        case .incompleteRange:
            "The library stopped sending audio before the requested range completed."
        case .integrityMismatch:
            "The streamed audio failed SHA-256 verification."
        case .cancelled:
            "Streaming was cancelled."
        }
    }
}

/// Coordinates content-addressed range resources used by playback.
///
/// Completed resources are promoted into the same verified cache used by
/// offline downloads. Partial resources are resumable but are never exposed
/// through `SQLiteMediaCache.localURL` until their complete SHA-256 matches.
final class ProgressiveMediaCoordinator: @unchecked Sendable {
    static let blockSize: Int64 = 64 * 1_024
    static let initialReadAhead: Int64 = 1_024 * 1_024
    static let rollingReadAhead: Int64 = 16 * 1_024 * 1_024
    static let maximumConnectionsPerHost = 8

    private let cacheDirectory: URL
    private let session: URLSession
    private let credential: HubDeviceCredential?
    private let didVerify:
        @Sendable (_ hash: String, _ url: URL, _ byteCount: Int64) -> Void
    private let shouldRetain:
        @Sendable (_ media: RemoteMedia) -> Bool
    private let lock = NSLock()
    private var resources: [String: ProgressiveMediaResource] = [:]
    private var activeContentHash: String?

    init(
        cacheDirectory: URL,
        credential: HubDeviceCredential?,
        pinnedTLSFingerprint: String?,
        shouldRetain: @escaping @Sendable (
            _ media: RemoteMedia
        ) -> Bool,
        didVerify: @escaping @Sendable (
            _ hash: String,
            _ url: URL,
            _ byteCount: Int64
        ) -> Void
    ) {
        self.cacheDirectory = cacheDirectory
        self.credential = credential
        self.shouldRetain = shouldRetain
        self.didVerify = didVerify
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost =
            Self.maximumConnectionsPerHost
        // Without this, Foundation's default 60s request timeout applies. A demand
        // read competes for the same `maximumConnectionsPerHost` slots as every
        // other resource's background read-ahead and speculative next-track
        // prefetch — when that pool is saturated (e.g. right after switching
        // songs), a newly issued high-priority fetch can sit queued behind that
        // congestion with no way to fail fast, so it just hangs until the default
        // 60s timeout finally releases it — surfacing as "wait about a minute and
        // it plays" (observed directly). A short timeout here lets `fetch(block:)`'s
        // existing 250ms/750ms retry-with-backoff recover in a couple of seconds
        // instead. 64KB range requests should complete in well under this even on a
        // slow connection.
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        if let pinnedTLSFingerprint, !pinnedTLSFingerprint.isEmpty {
            session = URLSession(
                configuration: configuration,
                delegate: PinnedTLSDelegate(
                    fingerprint: pinnedTLSFingerprint
                ),
                delegateQueue: nil
            )
        } else {
            session = URLSession(configuration: configuration)
        }
    }

    func resource(for media: RemoteMedia) throws -> ProgressiveMediaResource {
        lock.lock()
        defer { lock.unlock() }
        if let resource = resources[media.contentHash],
           resource.canResume {
            resource.resumeDemand()
            return resource
        }
        resources.removeValue(forKey: media.contentHash)
        let resource = try ProgressiveMediaResource(
            media: media,
            cacheDirectory: cacheDirectory,
            session: session,
            credential: credential,
            blockSize: Self.blockSize,
            shouldRetain: { [shouldRetain] in
                shouldRetain(media)
            },
            didVerify: didVerify
        )
        resources[media.contentHash] = resource
        return resource
    }

    /// Drops obsolete work without starting speculative network requests. The
    /// decoder gets the first request on a cold track.
    func prepareQueue(_ items: [PlaybackQueueItem]) {
        let queuedHashes = Set(items.compactMap { item in
            if case .remote(let media) = item.location {
                return media.contentHash
            }
            return nil
        })
        cancelResources(notIn: queuedHashes)
    }

    /// Starts bounded read-ahead only after the audio player reports that the
    /// decoder is active. This keeps container probes and first PCM ahead of
    /// all speculative work.
    func playbackStarted(
        _ items: [PlaybackQueueItem],
        at index: Int
    ) {
        guard items.indices.contains(index) else { return }
        let current = items[index]
        var activeResource: ProgressiveMediaResource?
        var activeHash: String?
        if case .remote(let media) = current.location,
           let resource = try? resource(for: media) {
            activeResource = resource
            activeHash = media.contentHash
        }

        lock.lock()
        let previousResource = activeContentHash.flatMap { hash in
            hash == activeHash ? nil : resources[hash]
        }
        activeContentHash = activeHash
        lock.unlock()
        previousResource?.endActiveStreaming()

        if let activeResource,
           case .remote(let media) = current.location {
            activeResource.beginActiveStreaming(
                initialReadAhead: min(
                    media.byteCount,
                    Self.initialReadAhead
                ),
                rollingReadAhead: Self.rollingReadAhead
            )
        }
        for item in items.dropFirst(index + 1).prefix(2) {
            guard case .remote(let media) = item.location,
                  let resource = try? resource(for: media) else {
                continue
            }
            resource.prefetch(offset: 0, length: Self.blockSize)
            if media.byteCount > Self.blockSize {
                resource.prefetch(
                    offset: media.byteCount - Self.blockSize,
                    length: Self.blockSize
                )
            }
        }
    }

    func cancelResources(notIn hashes: Set<String>) {
        lock.lock()
        let obsolete = resources.filter { !hashes.contains($0.key) }
        if let activeContentHash, !hashes.contains(activeContentHash) {
            self.activeContentHash = nil
        }
        obsolete.values.forEach { $0.cancelDemand() }
        for (hash, resource) in obsolete where resource.canDiscard {
            resources.removeValue(forKey: hash)
        }
        lock.unlock()
    }

}

final class ProgressiveMediaResource: @unchecked Sendable {
    /// Background ranges fill six slots while two remain available for
    /// decoder-demand reads and seeks. Small demand blocks preserve fast
    /// first sound; parallel read-ahead supplies sustained high-resolution
    /// playback without increasing that first blocking request.
    private static let maximumConcurrentFetches = 8
    private static let maximumConcurrentPrefetchFetches = 6

    private static let logger = Logger(
        subsystem: "com.othyn.aro",
        category: "ProgressiveRanges"
    )

    let media: RemoteMedia
    let partialURL: URL

    var bufferedFraction: Double {
        condition.lock()
        defer { condition.unlock() }
        guard blockCount > 0 else { return 0 }
        return min(Double(availableBlocks.count) / Double(blockCount), 1)
    }

    var isWaitingForData: Bool {
        condition.lock()
        defer { condition.unlock() }
        return waitingReaders > 0
    }

    var throughputBytesPerSecond: Double {
        condition.lock()
        defer { condition.unlock() }
        return measuredThroughput
    }

    var canResume: Bool {
        condition.lock()
        defer { condition.unlock() }
        return failure == nil
    }

    var canDiscard: Bool {
        condition.lock()
        defer { condition.unlock() }
        return inFlightBlocks.isEmpty && waitingReaders == 0
    }

    private struct ResumeState: Codable {
        let byteCount: Int64
        let availableBlocks: [Int64]
    }

    private let session: URLSession
    private let credential: HubDeviceCredential?
    private let blockSize: Int64
    private let blockCount: Int64
    private let resumeURL: URL
    private let destinationURL: URL
    private let usesEphemeralFiles: Bool
    private let condition = NSCondition()
    private let file: FileHandle
    private let didVerify:
        @Sendable (_ hash: String, _ url: URL, _ byteCount: Int64) -> Void
    private let shouldRetain: @Sendable () -> Bool
    private var availableBlocks = Set<Int64>()
    private var inFlightBlocks = Set<Int64>()
    private var inFlightPrefetchBlocks = Set<Int64>()
    /// Handles for the `Task` wrapping each in-flight `fetch(block:)` call, kept
    /// so `cancelDemand()` can actually stop them. `URLSession`'s async
    /// `data(for:)` observes Swift's cooperative cancellation and aborts the
    /// underlying HTTP request when its wrapping `Task` is cancelled — without
    /// this, an abandoned resource's background reads kept running to
    /// completion regardless, holding `maximumConnectionsPerHost` slots that a
    /// newly active track's demand fetches then had to queue behind (observed
    /// directly: dozens of range requests for a track the user had already
    /// skipped past, still arriving a minute later while a freshly clicked
    /// track sat waiting).
    private var inFlightTasks: [Int64: Task<Void, Never>] = [:]
    private var queuedDemandBlocks: [Int64] = []
    private var queuedDemandBlockSet = Set<Int64>()
    private var queuedPrefetchBlocks: [Int64] = []
    private var queuedPrefetchBlockSet = Set<Int64>()
    private var rollingPrefetchRanges: [ClosedRange<Int64>] = []
    private var rollingReadAhead: Int64 = 0
    private var failure: (any Error)?
    private var waitingReaders = 0
    private var verificationStarted = false
    private var demandCancelled = false
    private var measuredThroughput: Double = 0
    private var integrityFailureHandler:
        (@Sendable (_ message: String) -> Void)?

    init(
        media: RemoteMedia,
        cacheDirectory: URL,
        session: URLSession,
        credential: HubDeviceCredential?,
        blockSize: Int64,
        shouldRetain: @escaping @Sendable () -> Bool = { true },
        didVerify: @escaping @Sendable (
            _ hash: String,
            _ url: URL,
            _ byteCount: Int64
        ) -> Void
    ) throws {
        self.media = media
        self.session = session
        self.credential = credential
        self.blockSize = blockSize
        self.shouldRetain = shouldRetain
        blockCount = max(1, (media.byteCount + blockSize - 1) / blockSize)
        self.didVerify = didVerify
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        destinationURL = cacheDirectory.appendingPathComponent(
            media.contentHash
        )
        usesEphemeralFiles = !shouldRetain()
        if usesEphemeralFiles {
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "Aro/Streaming",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            let temporaryBase = temporaryDirectory.appendingPathComponent(
                "\(media.contentHash)-\(UUID().uuidString)"
            )
            partialURL = temporaryBase.appendingPathExtension("partial")
            resumeURL = temporaryBase.appendingPathExtension("ranges")
        } else {
            partialURL = destinationURL.appendingPathExtension(
                "streaming.partial"
            )
            resumeURL = destinationURL.appendingPathExtension(
                "streaming.ranges"
            )
        }
        if !FileManager.default.fileExists(atPath: partialURL.path) {
            FileManager.default.createFile(
                atPath: partialURL.path,
                contents: nil
            )
        }
        file = try FileHandle(forUpdating: partialURL)

        if !usesEphemeralFiles,
           let data = try? Data(contentsOf: resumeURL),
           let state = try? JSONDecoder().decode(ResumeState.self, from: data),
           state.byteCount == media.byteCount {
            availableBlocks = Set(
                state.availableBlocks.filter { $0 >= 0 && $0 < blockCount }
            )
        }
    }

    deinit {
        try? file.close()
        if usesEphemeralFiles {
            try? FileManager.default.removeItem(at: partialURL)
            try? FileManager.default.removeItem(at: resumeURL)
        }
    }

    func read(offset: Int64, length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset < media.byteCount else {
            return Data()
        }
        let boundedLength = min(
            Int64(length),
            media.byteCount - offset
        )
        let first = offset / blockSize
        let last = (offset + boundedLength - 1) / blockSize

        condition.lock()
        waitingReaders += 1
        defer {
            waitingReaders -= 1
            condition.unlock()
        }
        for block in first...last {
            while !availableBlocks.contains(block) {
                guard failure == nil, !demandCancelled else {
                    return nil
                }
                startFetchLocked(block: block, highPriority: true)
                condition.wait()
            }
        }

        do {
            try file.seek(toOffset: UInt64(offset))
            let data =
                try file.read(upToCount: Int(boundedLength)) ?? Data()
            queueRollingReadAheadLocked(
                after: offset + Int64(data.count)
            )
            return data
        } catch {
            failure = error
            return nil
        }
    }

    /// Marks this as the actively playing resource. The decoder has already
    /// won the cold-start race by the time this is called; subsequent reads
    /// continuously move the background window forward.
    func beginActiveStreaming(
        initialReadAhead: Int64,
        rollingReadAhead: Int64
    ) {
        condition.lock()
        self.rollingReadAhead = max(0, rollingReadAhead)
        let activeWindow = max(initialReadAhead, rollingReadAhead)
        if activeWindow > 0 {
            // This method is called only after the player reports that the
            // decoder is active. Fill the entire sustained-playback window
            // immediately: some decoders do not issue their next compressed
            // read until their PCM buffer is almost empty.
            let end = min(media.byteCount, activeWindow)
            let range = 0...max(0, (end - 1) / blockSize)
            queuePrefetchLocked(blocks: range)
            recordRollingPrefetchRangeLocked(range)
        }
        condition.unlock()
    }

    func prefetch(offset: Int64, length: Int64) {
        guard length > 0, offset < media.byteCount else { return }
        let first = max(0, offset) / blockSize
        let end = min(media.byteCount, offset + length)
        let last = max(first, (end - 1) / blockSize)
        condition.lock()
        queuePrefetchLocked(blocks: first...last)
        condition.unlock()
    }

    func hasAvailablePrefix(through byteCount: Int64) -> Bool {
        let requiredBlocks = min(
            blockCount,
            max(1, (byteCount + blockSize - 1) / blockSize)
        )
        condition.lock()
        defer { condition.unlock() }
        return (0..<requiredBlocks).allSatisfy {
            availableBlocks.contains($0)
        }
    }

    func cancelDemand() {
        condition.lock()
        demandCancelled = true
        rollingReadAhead = 0
        rollingPrefetchRanges = []
        queuedDemandBlocks = []
        queuedDemandBlockSet = []
        queuedPrefetchBlocks = []
        queuedPrefetchBlockSet = []
        // Only the *queued* work above is dropped by clearing those arrays — the
        // fetches already dispatched to the network keep running to completion
        // regardless, consuming a `maximumConnectionsPerHost` slot the whole
        // time. Actually cancelling their Tasks (outside the lock, since
        // `Task.cancel()` may synchronously resume a waiter) is what makes an
        // abandoned track stop competing with whichever one is now active.
        // `inFlightBlocks`/`inFlightPrefetchBlocks` are left alone here — the
        // cancelled fetch's own completion path (see `fetch(block:)`'s
        // `CancellationError`/`.cancelled` handling) is the single place that
        // clears those, so a fresh `startFetchLocked` can't race a duplicate
        // request for a block whose cancellation hasn't unwound yet.
        let tasksToCancel = inFlightTasks
        inFlightTasks.removeAll()
        condition.broadcast()
        condition.unlock()
        for task in tasksToCancel.values {
            task.cancel()
        }
    }

    func endActiveStreaming() {
        condition.lock()
        rollingReadAhead = 0
        rollingPrefetchRanges = []
        queuedPrefetchBlocks = []
        queuedPrefetchBlockSet = []
        condition.unlock()
    }

    func resumeDemand() {
        condition.lock()
        demandCancelled = false
        condition.unlock()
    }

    func onIntegrityFailure(
        _ handler: @escaping @Sendable (_ message: String) -> Void
    ) {
        condition.lock()
        integrityFailureHandler = handler
        condition.unlock()
    }

    private func startFetchLocked(block: Int64, highPriority: Bool) {
        guard failure == nil, !availableBlocks.contains(block) else {
            return
        }
        if inFlightBlocks.contains(block) {
            if highPriority {
                // The work is already useful to the decoder. Reclassifying it
                // releases a speculative slot so read-ahead can continue
                // without consuming either reserved demand slot.
                inFlightPrefetchBlocks.remove(block)
            }
            return
        }
        if highPriority {
            if queuedPrefetchBlockSet.remove(block) != nil {
                queuedPrefetchBlocks.removeAll { $0 == block }
            }
            guard !queuedDemandBlockSet.contains(block) else { return }
            guard inFlightBlocks.count < Self.maximumConcurrentFetches else {
                queuedDemandBlocks.append(block)
                queuedDemandBlockSet.insert(block)
                return
            }
        } else {
            guard !queuedDemandBlockSet.contains(block),
                  !queuedPrefetchBlockSet.contains(block) else {
                return
            }
            guard inFlightBlocks.count < Self.maximumConcurrentFetches,
                  inFlightPrefetchBlocks.count
                    < Self.maximumConcurrentPrefetchFetches else {
                queuedPrefetchBlocks.append(block)
                queuedPrefetchBlockSet.insert(block)
                return
            }
        }
        launchFetchLocked(block: block, isPrefetch: !highPriority)
    }

    private func dequeueDemandFetchLocked() -> Int64? {
        while !queuedDemandBlocks.isEmpty {
            let block = queuedDemandBlocks.removeFirst()
            queuedDemandBlockSet.remove(block)
            if !availableBlocks.contains(block),
               !inFlightBlocks.contains(block) {
                return block
            }
        }
        return nil
    }

    private func dequeuePrefetchFetchLocked() -> Int64? {
        while !queuedPrefetchBlocks.isEmpty {
            let block = queuedPrefetchBlocks.removeFirst()
            queuedPrefetchBlockSet.remove(block)
            if !availableBlocks.contains(block),
               !inFlightBlocks.contains(block) {
                return block
            }
        }
        return nil
    }

    private func removeQueuedBlocksLocked(
        in blocks: ClosedRange<Int64>
    ) {
        queuedDemandBlocks.removeAll { blocks.contains($0) }
        queuedDemandBlockSet.subtract(blocks)
        queuedPrefetchBlocks.removeAll { blocks.contains($0) }
        queuedPrefetchBlockSet.subtract(blocks)
    }

    private func launchQueuedFetchesLocked() {
        while inFlightBlocks.count < Self.maximumConcurrentFetches,
              let block = dequeueDemandFetchLocked() {
            launchFetchLocked(block: block, isPrefetch: false)
        }
        while queuedDemandBlocks.isEmpty,
              inFlightBlocks.count < Self.maximumConcurrentFetches,
              inFlightPrefetchBlocks.count
                < Self.maximumConcurrentPrefetchFetches,
              let block = dequeuePrefetchFetchLocked() {
            launchFetchLocked(block: block, isPrefetch: true)
        }
    }

    private func launchFetchLocked(
        block: Int64,
        isPrefetch: Bool
    ) {
        guard !inFlightBlocks.contains(block) else {
            return
        }
        inFlightBlocks.insert(block)
        if isPrefetch {
            inFlightPrefetchBlocks.insert(block)
        }
        inFlightTasks[block] = Task { [weak self] in
            await self?.fetch(block: block)
        }
    }

    private func queuePrefetchLocked(
        blocks: ClosedRange<Int64>
    ) {
        for block in blocks where !availableBlocks.contains(block) {
            startFetchLocked(block: block, highPriority: false)
        }
    }

    private func queueRollingReadAheadLocked(after offset: Int64) {
        guard rollingReadAhead > 0, offset < media.byteCount else {
            return
        }
        let end = min(media.byteCount, offset + rollingReadAhead)
        let desired = (offset / blockSize)...max(
            offset / blockSize,
            (end - 1) / blockSize
        )
        for range in uncoveredRollingRangesLocked(in: desired) {
            queuePrefetchLocked(blocks: range)
        }
        recordRollingPrefetchRangeLocked(desired)
    }

    private func uncoveredRollingRangesLocked(
        in desired: ClosedRange<Int64>
    ) -> [ClosedRange<Int64>] {
        var result: [ClosedRange<Int64>] = []
        var cursor = desired.lowerBound
        for existing in rollingPrefetchRanges {
            guard existing.upperBound >= cursor else { continue }
            guard existing.lowerBound <= desired.upperBound else { break }
            if existing.lowerBound > cursor {
                result.append(
                    cursor...min(
                        desired.upperBound,
                        existing.lowerBound - 1
                    )
                )
            }
            if existing.upperBound == Int64.max {
                return result
            }
            cursor = max(cursor, existing.upperBound + 1)
            if cursor > desired.upperBound {
                return result
            }
        }
        if cursor <= desired.upperBound {
            result.append(cursor...desired.upperBound)
        }
        return result
    }

    private func recordRollingPrefetchRangeLocked(
        _ newRange: ClosedRange<Int64>
    ) {
        var lower = newRange.lowerBound
        var upper = newRange.upperBound
        var retained: [ClosedRange<Int64>] = []
        var inserted = false

        for existing in rollingPrefetchRanges {
            if existing.upperBound < lower - 1 {
                retained.append(existing)
            } else if upper < existing.lowerBound - 1 {
                if !inserted {
                    retained.append(lower...upper)
                    inserted = true
                }
                retained.append(existing)
            } else {
                lower = min(lower, existing.lowerBound)
                upper = max(upper, existing.upperBound)
            }
        }
        if !inserted {
            retained.append(lower...upper)
        }
        rollingPrefetchRanges = retained
    }

    private func fetch(block: Int64) async {
        let start = block * blockSize
        let end = min(media.byteCount - 1, start + blockSize - 1)
        var request = URLRequest(url: media.downloadURL)
        request.setValue(
            "bytes=\(start)-\(end)",
            forHTTPHeaderField: "Range"
        )
        if let credential {
            request.setValue(
                "Bearer \(credential.credential)",
                forHTTPHeaderField: "Authorization"
            )
            request.setValue(
                credential.deviceID.uuidString,
                forHTTPHeaderField: "X-Aro-Device"
            )
        }

        for attempt in 0..<3 {
            do {
                let startedAt = Date()
                let (data, response) = try await session.data(for: request)
            let elapsedMilliseconds = Int(
                Date().timeIntervalSince(startedAt) * 1_000
            )
            guard let http = response as? HTTPURLResponse else {
                throw ProgressiveMediaError.invalidResponse
            }
            let writeOffset: Int64
            let blocks: ClosedRange<Int64>
            switch http.statusCode {
            case 206:
                let expectedPrefix = "bytes \(start)-\(end)/"
                guard http.value(forHTTPHeaderField: "Content-Range")?
                        .hasPrefix(expectedPrefix) == true else {
                    throw ProgressiveMediaError.invalidResponse
                }
                guard data.count == Int(end - start + 1) else {
                    throw ProgressiveMediaError.incompleteRange
                }
                writeOffset = start
                blocks = block...block
            case 200:
                guard !data.isEmpty,
                      Int64(data.count) == media.byteCount else {
                    throw ProgressiveMediaError.invalidResponse
                }
                writeOffset = 0
                blocks = 0...(blockCount - 1)
            default:
                throw URLError(.badServerResponse)
            }

            let shouldVerify = storeFetchedData(
                data,
                at: writeOffset,
                blocks: blocks,
                elapsed: max(Date().timeIntervalSince(startedAt), 0.001)
            )
            Self.logger.debug(
                "Fetched block \(block, privacy: .public) (\(data.count, privacy: .public) bytes) in \(elapsedMilliseconds, privacy: .public) ms"
            )
            if shouldVerify {
                await verifyAndPromote()
            }
                return
            } catch {
                // A deliberate `cancelDemand()` cancellation, not a real failure —
                // don't retry it (that would defeat the point of cancelling) and
                // don't poison the whole resource via `recordFailure` (which sets
                // a permanent `failure` that blocks every future fetch on it,
                // even though this resource may simply be resumed later).
                if error is CancellationError
                    || (error as? URLError)?.code == .cancelled {
                    clearInFlightOnCancel(block: block)
                    return
                }
                if attempt < 2, isRetryable(error) {
                    try? await Task.sleep(
                        for: .milliseconds(attempt == 0 ? 250 : 750)
                    )
                    continue
                }
                recordFailure(error, block: block)
                return
            }
        }
    }

    private func clearInFlightOnCancel(block: Int64) {
        condition.lock()
        inFlightBlocks.remove(block)
        inFlightPrefetchBlocks.remove(block)
        inFlightTasks.removeValue(forKey: block)
        condition.broadcast()
        condition.unlock()
    }

    private func isRetryable(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func storeFetchedData(
        _ data: Data,
        at offset: Int64,
        blocks: ClosedRange<Int64>,
        elapsed: TimeInterval
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        do {
            try file.seek(toOffset: UInt64(offset))
            try file.write(contentsOf: data)
            availableBlocks.formUnion(blocks)
            inFlightBlocks.subtract(blocks)
            inFlightPrefetchBlocks.subtract(blocks)
            for completed in blocks {
                inFlightTasks.removeValue(forKey: completed)
            }
            removeQueuedBlocksLocked(in: blocks)
            let sample = Double(data.count) / elapsed
            measuredThroughput = measuredThroughput == 0
                ? sample
                : measuredThroughput * 0.7 + sample * 0.3
            try persistResumeStateLocked()
            let shouldVerify =
                availableBlocks.count == Int(blockCount)
                && !verificationStarted
            verificationStarted = verificationStarted || shouldVerify
            launchQueuedFetchesLocked()
            condition.broadcast()
            return shouldVerify
        } catch {
            failLocked(error)
            return false
        }
    }

    private func recordFailure(
        _ error: any Error,
        block: Int64? = nil,
        notify: Bool = false
    ) {
        let hashPrefix = String(media.contentHash.prefix(12))
        Self.logger.error(
            "Range stream failed for \(hashPrefix, privacy: .public), block \(block ?? -1, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        condition.lock()
        if let block {
            inFlightBlocks.remove(block)
            inFlightPrefetchBlocks.remove(block)
            inFlightTasks.removeValue(forKey: block)
        }
        failLocked(error)
        let handler = notify ? integrityFailureHandler : nil
        condition.unlock()
        handler?(error.localizedDescription)
    }

    private func persistResumeStateLocked() throws {
        guard shouldRetain() else {
            try? FileManager.default.removeItem(at: resumeURL)
            return
        }
        let state = ResumeState(
            byteCount: media.byteCount,
            availableBlocks: availableBlocks.sorted()
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: resumeURL, options: .atomic)
    }

    private func verifyAndPromote() async {
        do {
            let digest = try await Task.detached { [partialURL] in
                let handle = try FileHandle(forReadingFrom: partialURL)
                defer { try? handle.close() }
                var hasher = SHA256()
                while let data = try handle.read(upToCount: 128 * 1_024),
                      !data.isEmpty {
                    hasher.update(data: data)
                }
                return hasher.finalize().map {
                    String(format: "%02x", $0)
                }.joined()
            }.value
            guard digest.caseInsensitiveCompare(media.contentHash)
                    == .orderedSame else {
                throw ProgressiveMediaError.integrityMismatch
            }
            try file.synchronize()
            guard shouldRetain() else {
                try? FileManager.default.removeItem(at: partialURL)
                try? FileManager.default.removeItem(at: resumeURL)
                return
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: partialURL)
            } else {
                try FileManager.default.moveItem(
                    at: partialURL,
                    to: destinationURL
                )
            }
            try? FileManager.default.removeItem(at: resumeURL)
            didVerify(media.contentHash, destinationURL, media.byteCount)
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            try? FileManager.default.removeItem(at: resumeURL)
            recordFailure(error, notify: true)
        }
    }

    private func failLocked(_ error: any Error) {
        failure = error
        condition.broadcast()
    }
}
