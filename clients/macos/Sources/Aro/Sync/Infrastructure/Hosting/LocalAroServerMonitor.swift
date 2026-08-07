import Darwin
import Foundation
import Observation
import SQLite3

enum LocalAroServerKind: String, Hashable, Sendable {
    case bundledHelper
    case standalone

    var label: String {
        switch self {
        case .bundledHelper:
            "Created by this Aro app"
        case .standalone:
            "Standalone Aro"
        }
    }
}

struct LocalAroServer: Identifiable, Hashable, Sendable {
    let pid: Int32
    let kind: LocalAroServerKind
    let listener: String
    let hubID: UUID?
    let displayName: String
    let dataPath: String?
    let sequence: Int64?
    let trackCount: Int64?
    let blobCount: Int64?

    var id: Int32 { pid }
}

@MainActor
@Observable
final class LocalAroServerMonitor {
    private let userID = getuid()
    var servers: [LocalAroServer] = []
    var errorMessage: String?
    var networkWarning: String?

    func refresh() {
        do {
            let helperPID = try bundledHelperPID()
            let listeners = try listeningProcesses()
            servers = listeners.compactMap { listener in
                makeServer(listener, helperPID: helperPID)
            }.sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .bundledHelper
                }
                return lhs.pid < rhs.pid
            }
            errorMessage = nil
            networkWarning = firewallWarning()
        } catch {
            servers = []
            errorMessage = error.localizedDescription
            networkWarning = nil
        }
    }

    func stopStandalone(_ server: LocalAroServer) {
        guard server.kind == .standalone,
              servers.contains(where: {
                  $0.pid == server.pid && $0.kind == .standalone
              }) else {
            errorMessage = "That standalone server is no longer running."
            return
        }
        guard Darwin.kill(server.pid, SIGTERM) == 0 else {
            errorMessage = String(cString: strerror(errno))
            return
        }
        servers.removeAll { $0.pid == server.pid }
        errorMessage = nil
    }

    func stopBundledService(_ server: LocalAroServer) {
        guard server.kind == .bundledHelper,
              (try? bundledHelperPID()) == server.pid else {
            errorMessage = "That Background Service is no longer running."
            return
        }
        do {
            _ = try run(
                "/bin/launchctl",
                arguments: [
                    "bootout",
                    "gui/\(userID)/com.imjacobclark.aro.server",
                ]
            )
            servers.removeAll { $0.pid == server.pid }
            errorMessage = nil
        } catch {
            errorMessage = "Unable to stop the Background Service: "
                + error.localizedDescription
        }
    }

    nonisolated static func parseConfiguration(
        _ contents: String
    ) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<separator]
                .trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               value.first == "\"",
               value.last == "\"" {
                value.removeFirst()
                value.removeLast()
                value = value
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            values[key] = value
        }
        return values
    }

    nonisolated static func configurationPath(
        command: String,
        kind: LocalAroServerKind,
        homeDirectory: URL
    ) -> String? {
        if let range = command.range(
            of: #"--config\s+(.+?)(?=\s+serve(?:\s|$)|$)"#,
            options: .regularExpression
        ) {
            var value = String(command[range])
                .replacingOccurrences(
                    of: #"^--config\s+"#,
                    with: "",
                    options: .regularExpression
                )
            if value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        guard kind == .bundledHelper else { return nil }
        return homeDirectory
            .appendingPathComponent(
                "Library/Application Support/Aro/Server/aro.toml"
            )
            .path
    }

    private func makeServer(
        _ listener: ListeningProcess,
        helperPID: Int32?
    ) -> LocalAroServer? {
        guard let command = try? processCommand(pid: listener.pid) else {
            return nil
        }
        let kind: LocalAroServerKind = listener.pid == helperPID
            ? .bundledHelper
            : .standalone
        let configPath = Self.configurationPath(
            command: command,
            kind: kind,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let config = configPath.flatMap {
            try? String(contentsOfFile: $0, encoding: .utf8)
        }.map(Self.parseConfiguration) ?? [:]
        let dataPath = config["data_dir"]
        let stats = dataPath.flatMap(readStats)
        return LocalAroServer(
            pid: listener.pid,
            kind: kind,
            listener: listener.address,
            hubID: config["hub_id"].flatMap(UUID.init(uuidString:)),
            displayName: config["display_name"] ?? "Aro Server",
            dataPath: dataPath,
            sequence: stats?.sequence,
            trackCount: stats?.tracks,
            blobCount: stats?.blobs
        )
    }

    private func readStats(dataPath: String) -> HubStats? {
        let databasePath = URL(fileURLWithPath: dataPath)
            .appendingPathComponent("hub.sqlite3")
            .path
        var connection: OpaquePointer?
        guard sqlite3_open_v2(
            databasePath,
            &connection,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK,
              let connection else {
            if connection != nil {
                sqlite3_close(connection)
            }
            return nil
        }
        defer { sqlite3_close(connection) }
        return HubStats(
            sequence: scalar(
                connection,
                sql: "SELECT COALESCE(MAX(sequence), 0) FROM operations"
            ),
            tracks: scalar(
                connection,
                sql: "SELECT COUNT(*) FROM tracks"
            ),
            blobs: scalar(
                connection,
                sql: "SELECT COUNT(*) FROM blobs"
            )
        )
    }

    private func scalar(
        _ connection: OpaquePointer,
        sql: String
    ) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            sql,
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
            ? sqlite3_column_int64(statement, 0)
            : nil
    }

    private func listeningProcesses() throws -> [ListeningProcess] {
        let output = try run(
            "/usr/sbin/lsof",
            arguments: [
                "-nP",
                "-a",
                "-u",
                String(userID),
                "-c",
                "aro-server",
                "-iTCP",
                "-sTCP:LISTEN",
                "-Fpcn",
            ],
            acceptsNonzeroExit: true
        )
        var pid: Int32?
        var command: String?
        var listeners: [ListeningProcess] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int32(value)
                command = nil
            case "c":
                command = value
            case "n":
                if let pid,
                   command == "aro-server" {
                    listeners.append(
                        ListeningProcess(pid: pid, address: value)
                    )
                }
            default:
                continue
            }
        }
        return Array(Set(listeners))
    }

    private func bundledHelperPID() throws -> Int32? {
        let output = try run(
            "/bin/launchctl",
            arguments: [
                "print",
                "gui/\(userID)/com.imjacobclark.aro.server",
            ],
            acceptsNonzeroExit: true
        )
        guard let match = output.firstMatch(
            of: #/\bpid = ([0-9]+)/#
        ) else {
            return nil
        }
        return Int32(match.1)
    }

    private func processCommand(pid: Int32) throws -> String {
        try run(
            "/bin/ps",
            arguments: ["-p", String(pid), "-o", "command="]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firewallWarning() -> String? {
        guard !servers.isEmpty else { return nil }
        let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        let blockAll = try? run(
            tool,
            arguments: ["--getblockall"],
            acceptsNonzeroExit: true
        )
        if blockAll?.localizedCaseInsensitiveContains(
            "blocking all"
        ) == true {
            return "macOS Firewall is blocking all incoming connections. "
                + "Other Aros cannot connect to this Background Service."
        }
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/aro-server")
            .path
        let appStatus = try? run(
            tool,
            arguments: ["--getappblocked", helper],
            acceptsNonzeroExit: true
        )
        if appStatus?.localizedCaseInsensitiveContains("is blocked") == true {
            return "macOS Firewall is blocking incoming connections to the "
                + "Aro Background Service."
        }
        return nil
    }

    private func run(
        _ executable: String,
        arguments: [String],
        acceptsNonzeroExit: Bool = false
    ) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        guard acceptsNonzeroExit || process.terminationStatus == 0 else {
            throw LocalServerMonitorError.commandFailed(output)
        }
        return output
    }
}

private struct ListeningProcess: Hashable {
    let pid: Int32
    let address: String
}

private struct HubStats {
    let sequence: Int64?
    let tracks: Int64?
    let blobs: Int64?
}

private enum LocalServerMonitorError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let output):
            output.isEmpty
                ? "Unable to inspect local Aro servers."
                : output
        }
    }
}
