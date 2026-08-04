import Foundation
import AroCommon

struct SyncRunResult: Sendable {
    let uploadedOperations: Int
    let appliedOperations: Int
    let cursor: UInt64
    let canContribute: Bool
}

actor HubSyncCoordinator {
    private let hubID: UUID
    private let client: AroSyncClient
    private let credential: HubDeviceCredential
    private let operations: SQLiteSyncOperationStore
    private let offlineTrackCount: UInt64?
    private let sourceMode: String

    init(
        hubID: UUID,
        client: AroSyncClient,
        credential: HubDeviceCredential,
        operations: SQLiteSyncOperationStore,
        offlineTrackCount: UInt64? = nil,
        sourceMode: String = "referenced"
    ) {
        self.hubID = hubID
        self.client = client
        self.credential = credential
        self.operations = operations
        self.offlineTrackCount = offlineTrackCount
        self.sourceMode = sourceMode
    }

    func synchronize() async throws -> SyncRunResult {
        _ = try await client.compatibleHubInfo()
        let pending = operations.pending(limit: 200)
        var outgoing = try pending.compactMap { pending -> SyncOperation? in
            if pending.entityType == "track_state" {
                let hubTrackID = operations.hubTrackID(
                    localTrackID: pending.entityID,
                    hubID: hubID
                ) ?? pending.entityID
                return try pending.wireOperation(entityID: hubTrackID)
            }
            if pending.entityType == "listening_session" {
                let original = try pending.wireOperation()
                guard case .object(var payload) = original.payload,
                      case .string(let localTrackID)? = payload["track_id"] else {
                    return nil
                }
                let hubTrackID = operations.hubTrackID(
                    localTrackID: localTrackID,
                    hubID: hubID
                ) ?? localTrackID
                payload["track_id"] = .string(hubTrackID)
                return try pending.wireOperation(
                    payload: .object(payload)
                )
            }
            return try pending.wireOperation()
        }
        let access = try await client.deviceAccess(credential: credential)
        var sources: [SourceHealthReport] = []
        if access.canContribute {
            let contributions = operations.musicContributions(hubID: hubID)
            for contribution in contributions {
                try Task.checkCancellation()
                try await client.uploadBlob(
                    fileURL: contribution.fileURL,
                    expectedHash: contribution.contentHash,
                    expectedSize: contribution.byteCount,
                    credential: credential
                )
                outgoing.append(contribution.operation)
            }
            sources = operations.sourceHealthReports(mode: sourceMode)
        }
        var cursor = operations.serverCursor(hubID: hubID)
        var uploaded = 0
        var applied = 0
        var firstPage = true

        repeat {
            try Task.checkCancellation()
            let response = try await client.exchange(
                SyncExchangeRequest(
                    afterSequence: cursor,
                    operations: firstPage ? outgoing : [],
                    deviceReport: firstPage
                        ? DeviceSyncReport(
                            offlineTrackCount: offlineTrackCount ?? 0,
                            sources: sources
                        )
                        : nil
                ),
                credential: credential
            )
            if firstPage {
                let acceptedIDs = Set(
                    response.accepted.map(\.operationID)
                )
                operations.markSent(
                    pending
                        .filter { acceptedIDs.contains($0.id) }
                        .map(\.id)
                )
                uploaded = acceptedIDs.count
            }
            for change in response.changes {
                try Task.checkCancellation()
                if try operations.applyRemote(change, hubID: hubID) {
                    applied += 1
                }
            }
            cursor = response.nextCursor
            operations.updateCursor(hubID: hubID, sequence: cursor)
            firstPage = false
            if !response.hasMore {
                break
            }
        } while true

        return SyncRunResult(
            uploadedOperations: uploaded,
            appliedOperations: applied,
            cursor: cursor,
            canContribute: access.canContribute
        )
    }
}

/// Pushes durable device-authored intent without subscribing a streaming client
/// to the hub's full CRDT history. Canonical catalogue state comes from the resolved
/// catalogue API; this path exists only for offline-created edits/history/favourites.
actor HubMutationPushCoordinator {
    private let hubID: UUID
    private let client: AroSyncClient
    private let credential: HubDeviceCredential?
    private let operations: SQLiteSyncOperationStore

    init(
        hubID: UUID,
        client: AroSyncClient,
        credential: HubDeviceCredential?,
        operations: SQLiteSyncOperationStore
    ) {
        self.hubID = hubID
        self.client = client
        self.credential = credential
        self.operations = operations
    }

    func push() async throws -> Int {
        let pending = operations.pending(limit: 200)
        let outgoing = try pending.compactMap { pending -> SyncOperation? in
            if pending.entityType == "track_state" {
                let hubTrackID = operations.hubTrackID(
                    localTrackID: pending.entityID,
                    hubID: hubID
                ) ?? pending.entityID
                return try pending.wireOperation(entityID: hubTrackID)
            }
            if pending.entityType == "listening_session" {
                let original = try pending.wireOperation()
                guard case .object(var payload) = original.payload,
                      case .string(let localTrackID)? = payload["track_id"] else {
                    return nil
                }
                let hubTrackID = operations.hubTrackID(
                    localTrackID: localTrackID,
                    hubID: hubID
                ) ?? localTrackID
                payload["track_id"] = .string(hubTrackID)
                return try pending.wireOperation(payload: .object(payload))
            }
            return try pending.wireOperation()
        }
        guard !outgoing.isEmpty else { return 0 }
        // Upload-only: this path exists to flush the outbox, and the full sync
        // loop is what pulls changes down. Ask for none with an explicit limit
        // of zero and report the cursor we genuinely hold — an out-of-range
        // cursor used as a "send me nothing" sentinel reads as a real position
        // to the hub and cannot survive a signed-integer column.
        let response = try await client.exchange(
            SyncExchangeRequest(
                afterSequence: operations.serverCursor(hubID: hubID),
                limit: 0,
                operations: outgoing
            ),
            credential: credential
        )
        let accepted = Set(response.accepted.map(\.operationID))
        operations.markSent(
            pending.filter { accepted.contains($0.id) }.map(\.id)
        )
        return accepted.count
    }
}
