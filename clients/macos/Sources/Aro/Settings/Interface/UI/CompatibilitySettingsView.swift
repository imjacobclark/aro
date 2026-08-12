import AroCommon
import SwiftUI

/// Keeping a second, lossless copy of the tracks that only some devices can play.
///
/// Aro's promise is that it preserves exactly what you own, and that promise is also why a
/// library can be unplayable on half the devices that ask for it: Apple Lossless plays on a
/// Mac and in Safari, and in no other browser. Until now the only answer was the Opus ladder,
/// which is a fine way to save data and the wrong way to hear a lossless record.
///
/// So this offers the other answer — a FLAC copy of just those tracks, lossless, playable
/// everywhere. Three things are said plainly because each of them is the thing someone
/// worries about: the original is never touched, the copies live apart from the library, and
/// the cost is a second copy of *what needs converting* rather than of everything.
struct CompatibilitySettingsView: View {
    /// `nil` on a library with no hub — there is nothing to convert and nowhere to put it.
    var plan: (() async -> RemoteCompatibilityPlan?)?
    var start: (() async -> RemoteSyncJob?)?
    var progress: ((UUID) async -> RemoteSyncJob?)?
    var cleanup: (() async -> RemoteCompatibilityCleanupResponse?)?

    @State private var quoted: RemoteCompatibilityPlan?
    @State private var loading = false
    @State private var confirmingConversion = false
    @State private var confirmingCleanup = false
    @State private var job: RemoteSyncJob?
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Convert library for maximum cross-device compatibility")
                    .font(.headline)
                Text(
                    "Some formats only play on some devices. Apple Lossless, for one, plays "
                    + "on a Mac and in Safari but in no other browser. Aro can keep a second, "
                    + "lossless FLAC copy of those tracks so every Aro plays them properly "
                    + "instead of falling back to a re-encode that loses quality."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(
                    "Your music is never modified, renamed, or replaced. The copies are kept "
                    + "inside Aro, separately from your library and from Aro's synced audio, "
                    + "and you can delete them at any time."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Compatibility")
            }

            if let quoted {
                Section("Library") {
                    LabeledContent("Converted") {
                        Text("\(quoted.tracksConverted) tracks")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("To convert") {
                        Text("\(quoted.tracksPending) tracks")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Already compatible") {
                        Text("\(quoted.tracksAlreadyCompatible) tracks")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Space used") {
                        Text(byteText(quoted.usedBytes))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if quoted.tracksPending > 0 {
                        Button("Convert \(quoted.tracksPending) Tracks") {
                            confirmingConversion = true
                        }
                        .disabled(start == nil || job?.state == .running)
                        Text(
                            "\(durationText(quoted.pendingAudioSeconds)) of music, needing "
                            + "about \(byteText(quoted.estimatedBytes)). Your hub converts in "
                            + "the background, one track at a time, and stays usable while it "
                            + "works."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Everything that needs a compatible copy has one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if quoted.tracksConverted > 0 {
                        Button("Delete Compatible Copies", role: .destructive) {
                            confirmingCleanup = true
                        }
                        .disabled(cleanup == nil)
                    }
                }
            }

            if let job, job.state == .running || job.state == .pending {
                Section("Converting") {
                    ProgressView(
                        value: Double(job.completedUnits),
                        total: Double(max(job.totalUnits, 1))
                    ) {
                        Text("\(job.completedUnits) of \(job.totalUnits) tracks")
                    }
                    Text("You can keep listening while this runs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .confirmationDialog(
            "Convert \(quoted?.tracksPending ?? 0) tracks?",
            isPresented: $confirmingConversion,
            titleVisibility: .visible
        ) {
            Button("Convert") { Task { await beginConversion() } }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(conversionMessage)
        }
        .confirmationDialog(
            "Delete the compatible copies?",
            isPresented: $confirmingCleanup,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await runCleanup() } }
            Button("Keep", role: .cancel) {}
        } message: {
            Text(
                "This frees the space they use. Your library is untouched — these are extra "
                + "copies Aro made, and it can make them again later."
            )
        }
        .overlay {
            if loading && quoted == nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var conversionMessage: String {
        guard let quoted else { return "" }
        return "About \(durationText(quoted.estimatedSeconds)) of work, using around "
            + "\(byteText(quoted.estimatedBytes)). It runs in the background and you can "
            + "keep listening."
    }

    private func refresh() async {
        guard let plan else { return }
        loading = true
        defer { loading = false }
        quoted = await plan()
    }

    private func beginConversion() async {
        guard let start else { return }
        guard let started = await start() else {
            statusMessage = "The library could not start converting."
            return
        }
        job = started
        await follow(started.jobID)
        await refresh()
    }

    /// Polls until the job stops. The hub converts one track at a time, so this is slow by
    /// design and there is nothing to watch second by second.
    private func follow(_ id: UUID) async {
        guard let progress else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard let latest = await progress(id) else { return }
            job = latest
            if latest.state != .running && latest.state != .pending { return }
        }
    }

    private func runCleanup() async {
        guard let cleanup else { return }
        guard let result = await cleanup() else {
            statusMessage = "The copies could not be removed."
            return
        }
        statusMessage = result.removed == 0
            ? "There was nothing to remove."
            : "Removed \(result.removed) copies and freed \(byteText(result.freedBytes))."
        await refresh()
    }

    private func durationText(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .full
        return formatter.string(from: max(seconds, 1)) ?? "a moment"
    }

    private func byteText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
