import Foundation
import Observation
import AroCommon

@MainActor
@Observable
final class LibraryProfileRegistry {
    private enum Key {
        static let snapshot = "library.profileRegistry.v1"
    }

    private let defaults: UserDefaults
    private(set) var profiles: [LibraryProfile] = []
    private(set) var activeProfileID: UUID?
    var setupDismissed = false {
        didSet { save() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let isIsolatedUITest = ProcessInfo.processInfo.environment[
            "ARO_UI_TEST_ROOT"
        ] != nil
        if !isIsolatedUITest {
            LibraryDatabase.prepareDefaultStore()
        }
        if let data = defaults.data(forKey: Key.snapshot),
           let snapshot = try? JSONDecoder().decode(
            LibraryProfileSnapshot.self,
            from: data
           ) {
            profiles = snapshot.profiles
            activeProfileID = snapshot.activeProfileID
            setupDismissed = snapshot.setupDismissed
        }
        if !isIsolatedUITest {
            repairDatabaseLocations()
        }
    }

    var activeProfile: LibraryProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    var isConfigured: Bool {
        !profiles.isEmpty
    }

    func migrateLegacyState(
        databaseURL: URL,
        hasLocalLibrary: Bool,
        hostingDataLocation: String,
        memberships: [StoredHubMembershipSummary],
        deviceName: String,
        prepareRemoteProfile: (
            LibraryProfile,
            StoredHubMembershipSummary
        ) -> Void
    ) {
        guard profiles.isEmpty else { return }

        let roots = Self.profileRoots()
        var migrated: [LibraryProfile] = []
        if hasLocalLibrary || !hostingDataLocation.isEmpty {
            let id = UUID()
            let profile = LibraryProfile(
                    id: id,
                    name: "\(deviceName)’s Music Library",
                    kind: .local,
                    databasePath: databaseURL.path,
                    mediaPath: roots
                        .appendingPathComponent(id.uuidString)
                        .appendingPathComponent("Media")
                        .path,
                    managedMusicPath: nil,
                    referencedMusicPaths: [],
                    hubID: nil,
                    baseURL: nil,
                    sharingEnabled: !hostingDataLocation.isEmpty,
                    offlinePolicy: .stream,
                    storageLimitBytes: nil,
                    createdAt: .now,
                    lastActivatedAt: .now
                )
            migrated.append(profile)
        }

        for membership in memberships {
            let id = UUID()
            let profile = LibraryProfile(
                    id: id,
                    name: membership.displayName,
                    kind: .remote,
                    databasePath: migrated.isEmpty
                        ? databaseURL.path
                        : Self.databaseURL(profileID: id).path,
                    mediaPath: roots
                        .appendingPathComponent(id.uuidString)
                        .appendingPathComponent("Media")
                        .path,
                    managedMusicPath: nil,
                    referencedMusicPaths: [],
                    hubID: membership.hubID,
                    baseURL: membership.baseURL,
                    sharingEnabled: false,
                    offlinePolicy: membership.replicaMode == .fullMirror
                        ? .fullLibrary
                        : .stream,
                    storageLimitBytes: nil,
                    createdAt: membership.joinedAt,
                    lastActivatedAt: membership.joinedAt
            )
            migrated.append(profile)
            if profile.databasePath != databaseURL.path {
                prepareRemoteProfile(profile, membership)
            }
        }

        profiles = migrated
        activeProfileID = migrated.first(where: { $0.kind == .local })?.id
            ?? migrated.max(by: {
                $0.lastActivatedAt < $1.lastActivatedAt
            })?.id
        save()
    }

    @discardableResult
    func createLocal(
        name: String,
        managedMusicPath: String?,
        referencedMusicPaths: [String] = [],
        sharingEnabled: Bool
    ) -> LibraryProfile {
        let id = UUID()
        let profile = LibraryProfile(
            id: id,
            name: name,
            kind: .local,
            databasePath: LibraryDatabase.defaultURL().path,
            mediaPath: Self.profileRoots()
                .appendingPathComponent(id.uuidString)
                .appendingPathComponent("Media")
                .path,
            managedMusicPath: managedMusicPath,
            referencedMusicPaths: referencedMusicPaths,
            hubID: nil,
            baseURL: nil,
            sharingEnabled: sharingEnabled,
            offlinePolicy: .stream,
            storageLimitBytes: nil,
            createdAt: .now,
            lastActivatedAt: .now
        )
        addAndActivate(profile)
        return profile
    }

    @discardableResult
    func createRemote(
        name: String,
        hubID: UUID,
        baseURL: URL,
        policy: OfflineDownloadPolicy
    ) -> LibraryProfile {
        let id = UUID()
        let profile = LibraryProfile(
            id: id,
            name: name,
            kind: .remote,
            databasePath: Self.databaseURL(profileID: id).path,
            mediaPath: Self.profileRoots()
                .appendingPathComponent(id.uuidString)
                .appendingPathComponent("Media")
                .path,
            managedMusicPath: nil,
            referencedMusicPaths: [],
            hubID: hubID,
            baseURL: baseURL,
            sharingEnabled: false,
            offlinePolicy: policy,
            storageLimitBytes: nil,
            createdAt: .now,
            lastActivatedAt: .now
        )
        addAndActivate(profile)
        return profile
    }

    func activate(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        activeProfileID = id
        profiles[index].lastActivatedAt = .now
        save()
    }

    func update(_ profile: LibraryProfile) {
        guard let index = profiles.firstIndex(where: {
            $0.id == profile.id
        }) else {
            return
        }
        profiles[index] = profile
        save()
    }

    func dismissSetup() {
        setupDismissed = true
    }

    private func addAndActivate(_ profile: LibraryProfile) {
        profiles.append(profile)
        activeProfileID = profile.id
        setupDismissed = false
        save()
    }

    private func save() {
        let snapshot = LibraryProfileSnapshot(
            profiles: profiles,
            activeProfileID: activeProfileID,
            setupDismissed: setupDismissed
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Key.snapshot)
        }
    }

    private func repairDatabaseLocations() {
        var changed = false
        for index in profiles.indices {
            let profile = profiles[index]
            let leakedTestPath = profile.databasePath.contains(
                "aro-redesign-ui-profile"
            )
            let legacyLocalPath = profile.kind == .local
                && URL(fileURLWithPath: profile.databasePath)
                    .standardizedFileURL
                    == LibraryDatabase.legacyDefaultURL().standardizedFileURL
            if leakedTestPath || legacyLocalPath {
                let destination = profile.kind == .local
                    ? LibraryDatabase.defaultURL()
                    : Self.databaseURL(profileID: profile.id)
                LibraryDatabase.copyStoreIfNeeded(
                    from: URL(fileURLWithPath: profile.databasePath),
                    to: destination
                )
                profiles[index].databasePath = destination.path
                changed = true
            }

            if profile.mediaPath.contains("aro-redesign-ui-profile") {
                let destination = Self.profileRoots()
                    .appendingPathComponent(
                        profile.id.uuidString,
                        isDirectory: true
                    )
                    .appendingPathComponent("Media", isDirectory: true)
                profiles[index].mediaPath = destination.path
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    private static func profileRoots() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Aro/Libraries", isDirectory: true)
    }

    private static func databaseURL(profileID: UUID) -> URL {
        profileRoots()
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
            .appendingPathComponent("Library.sqlite3")
    }
}
