import Foundation
import Observation
import OSLog
import AroCommon

@MainActor
@Observable
final class LibraryProfileRegistry {
    private static let logger = Logger(
        subsystem: "com.othyn.aro",
        category: "LibraryProfileRegistry"
    )

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
        if let data = defaults.data(forKey: Key.snapshot) {
            do {
                let snapshot = try JSONDecoder().decode(
                    LibraryProfileSnapshot.self,
                    from: data
                )
                profiles = snapshot.profiles
                activeProfileID = snapshot.activeProfileID
                setupDismissed = snapshot.setupDismissed
            } catch {
                Self.logger.error(
                    "Could not decode saved library profiles; starting from an empty list: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if removeDuplicateRemoteProfiles() {
            save()
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

    /// Repairs or reconnects an existing remote library in place. Pairing
    /// credentials may be renewed independently of the replica database, so a
    /// reconnect must not create another sidebar entry or discard downloads.
    @discardableResult
    func upsertRemote(
        name: String,
        hubID: UUID,
        baseURL: URL,
        policy: OfflineDownloadPolicy
    ) -> LibraryProfile {
        let matching = profiles.indices.filter {
            profiles[$0].kind == .remote && profiles[$0].hubID == hubID
        }
        let selectedIndex = matching.first {
            profiles[$0].id == activeProfileID
        } ?? matching.max {
            profiles[$0].lastActivatedAt < profiles[$1].lastActivatedAt
        }
        guard let selectedIndex else {
            return createRemote(
                name: name,
                hubID: hubID,
                baseURL: baseURL,
                policy: policy
            )
        }

        profiles[selectedIndex].name = name
        profiles[selectedIndex].baseURL = baseURL
        profiles[selectedIndex].offlinePolicy = policy
        profiles[selectedIndex].lastActivatedAt = .now
        activeProfileID = profiles[selectedIndex].id
        removeDuplicateRemoteProfiles()
        save()
        return profiles.first {
            $0.kind == .remote && $0.hubID == hubID
        }!
    }

    /// Older builds could register the same remote library more than once.
    /// Keep the active replica (or the most recently used one) and remove only
    /// the duplicate registry entries. Their files are deliberately left
    /// untouched so this migration can never discard downloaded music.
    @discardableResult
    private func removeDuplicateRemoteProfiles() -> Bool {
        let hubIDs = Set(
            profiles.compactMap { profile in
                profile.kind == .remote ? profile.hubID : nil
            }
        )
        var changed = false
        for hubID in hubIDs {
            let matches = profiles.filter {
                $0.kind == .remote && $0.hubID == hubID
            }
            guard matches.count > 1 else { continue }
            let kept = matches.first {
                $0.id == activeProfileID
            } ?? matches.max {
                $0.lastActivatedAt < $1.lastActivatedAt
            }!
            profiles.removeAll {
                $0.kind == .remote
                    && $0.hubID == hubID
                    && $0.id != kept.id
            }
            if matches.contains(where: { $0.id == activeProfileID }) {
                activeProfileID = kept.id
            }
            changed = true
        }
        return changed
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

    /// Forgets a profile's registry entry, reassigning `activeProfileID` if it
    /// was the active one. Callers are responsible for switching any live
    /// runtime off this profile *before* calling this (see
    /// `AroApp.forgetProfile`) and for deleting its on-disk database/media —
    /// this only removes the pairing record itself.
    func remove(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        profiles.remove(at: index)
        if activeProfileID == id {
            activeProfileID = profiles.first(where: { $0.kind == .local })?.id
                ?? profiles.max(by: {
                    $0.lastActivatedAt < $1.lastActivatedAt
                })?.id
        }
        save()
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

    /// The per-profile root directory containing that profile's database
    /// (plus WAL/SHM sidecars) and its `Media` cache — everything a "forget
    /// this library" action needs to delete for a remote profile. Not valid
    /// for `.local` profiles, which use the single shared default database
    /// instead (see `createLocal`).
    static func profileDirectory(profileID: UUID) -> URL {
        profileRoots()
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    private static func profileRoots() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Aro/Libraries", isDirectory: true)
    }

    private static func databaseURL(profileID: UUID) -> URL {
        profileDirectory(profileID: profileID)
            .appendingPathComponent("Library.sqlite3")
    }
}
