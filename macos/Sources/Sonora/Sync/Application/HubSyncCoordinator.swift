import Foundation
import SonoraCommon

struct SyncRunResult: Sendable {
    let uploadedOperations: Int
    let appliedOperations: Int
    let cursor: UInt64
}

actor HubSyncCoordinator {
    private let hubID: UUID
    private let client: SonoraSyncClient
    private let credential: HubDeviceCredential
    private let operations: SQLiteSyncOperationStore

    init(
        hubID: UUID,
        client: SonoraSyncClient,
        credential: HubDeviceCredential,
        operations: SQLiteSyncOperationStore
    ) {
        self.hubID = hubID
        self.client = client
        self.credential = credential
        self.operations = operations
    }

    func synchronize() async throws -> SyncRunResult {
        let pending = operations.pending(limit: 200)
        let outgoing = try pending.compactMap { pending -> SyncOperation? in
            if pending.entityType == "track_state" {
                guard let hubTrackID = operations.hubTrackID(
                    localTrackID: pending.entityID,
                    hubID: hubID
                ) else {
                    return nil
                }
                return try pending.wireOperation(entityID: hubTrackID)
            }
            if pending.entityType == "listening_session" {
                let original = try pending.wireOperation()
                guard case .object(var payload) = original.payload,
                      case .string(let localTrackID)? = payload["track_id"],
                      let hubTrackID = operations.hubTrackID(
                        localTrackID: localTrackID,
                        hubID: hubID
                      ) else {
                    return nil
                }
                payload["track_id"] = .string(hubTrackID)
                return try pending.wireOperation(
                    payload: .object(payload)
                )
            }
            return try pending.wireOperation()
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
                    operations: firstPage ? outgoing : []
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
            cursor: cursor
        )
    }
}
