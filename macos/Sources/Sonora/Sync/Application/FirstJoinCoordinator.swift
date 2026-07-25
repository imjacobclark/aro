import Foundation
import SonoraCommon

struct FirstJoinCommitResult: Sendable {
    let job: RemoteSyncJob
    let backupURL: URL
}

enum FirstJoinError: LocalizedError {
    case unresolvedConflicts

    var errorDescription: String? {
        "Every first-join conflict must be resolved before committing."
    }
}

actor FirstJoinCoordinator {
    private let client: SonoraSyncClient
    private let credential: HubDeviceCredential
    private let libraryFiles: any LibraryFileManaging

    init(
        client: SonoraSyncClient,
        credential: HubDeviceCredential,
        libraryFiles: any LibraryFileManaging
    ) {
        self.client = client
        self.credential = credential
        self.libraryFiles = libraryFiles
    }

    func preview(
        manifest: [SyncManifestEntry]
    ) async throws -> FirstJoinPreview {
        try await client.previewJoin(
            JoinPreviewRequest(
                deviceID: credential.deviceID,
                manifest: manifest
            ),
            credential: credential
        )
    }

    func commit(
        preview: FirstJoinPreview,
        resolutions: [String: SyncConflictChoice]
    ) async throws -> FirstJoinCommitResult {
        for conflict in preview.conflicts {
            guard resolutions[conflict.resolutionKey] != nil else {
                throw FirstJoinError.unresolvedConflicts
            }
        }
        try Task.checkCancellation()
        let backupURL = try createBackup()
        try Task.checkCancellation()
        let job = try await client.commitJoin(
            JoinCommitRequest(
                previewID: preview.previewID,
                resolutions: resolutions
            ),
            credential: credential
        )
        return FirstJoinCommitResult(job: job, backupURL: backupURL)
    }

    private func createBackup() throws -> URL {
        let directory = libraryFiles.libraryURL
            .deletingLastPathComponent()
            .appendingPathComponent("Sync Backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let backup = directory.appendingPathComponent(
            "Before First Join \(UUID().uuidString).sqlite3"
        )
        try libraryFiles.exportLibrary(to: backup)
        return backup
    }
}
