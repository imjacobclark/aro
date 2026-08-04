import AroCommon
import SwiftUI

/// Chooses how much data streaming and offline copies cost.
///
/// A losslessly-ripped library is enormous next to what a phone on a mobile connection
/// needs — roughly 24 MB a track against a little over 2 MB at Saver. Converting is real
/// work though, and how much depends entirely on the machine doing it: the same library is
/// minutes on a fast hub and hours on a small one. So nothing is converted until the hub has
/// quoted the cost and it has been accepted, and progress is visible while it runs.
///
/// Converted audio lives inside Aro's own storage. It is never written into a watched
/// folder and never becomes a library track, so it cannot appear alongside the music it was
/// made from.
struct LowDataSettingsView: View {
    @Bindable var preferences: SyncPreferences
    /// `nil` on a library with no hub to convert anything — a local library reads its own
    /// files off disk, where there is no bandwidth to save and re-encoding would only lose
    /// quality to save space Aro doesn't control.
    var plan: ((StreamQuality) async -> RemoteTranscodePlan?)?
    var start: ((StreamQuality) async -> RemoteSyncJob?)?
    var progress: ((UUID) async -> RemoteSyncJob?)?
    var cleanup: ((StreamQuality) async -> RemoteTranscodeCleanupResponse?)?
    var usage: (() async -> [RemoteTranscodeUsage])?

    @State private var pendingQuality: StreamQuality?
    @State private var quotedPlan: RemoteTranscodePlan?
    @State private var quoting = false
    @State private var job: RemoteSyncJob?
    @State private var storedUsage: [RemoteTranscodeUsage] = []
    @State private var cleanupOffer: StreamQuality?
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Streaming", selection: streamBinding) {
                    ForEach(StreamQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                Text(preferences.streamQuality.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Playback Quality")
            } footer: {
                Text("Applies to music streamed from the library. Lower quality uses less bandwidth.")
                    .font(.caption)
            }

            Section {
                Picker("Downloads", selection: downloadBinding) {
                    ForEach(StreamQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                Text(preferences.downloadQuality.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Download Quality")
            } footer: {
                Text("Applies to music kept for offline listening. Lower quality uses less disk space.")
                    .font(.caption)
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

            if !storedUsage.isEmpty {
                Section("Converted Audio") {
                    ForEach(storedUsage) { entry in
                        LabeledContent(
                            StreamQuality(rawValue: entry.quality)?.title ?? entry.quality
                        ) {
                            Text("\(entry.tracks) tracks · \(byteText(entry.bytes))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Stored inside Aro, never added to your library.")
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
        .task { await refreshUsage() }
        .confirmationDialog(
            quoteTitle,
            isPresented: Binding(
                get: { quotedPlan != nil },
                set: { if !$0 { quotedPlan = nil; pendingQuality = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Convert") { Task { await beginConversion() } }
            Button("Not Now", role: .cancel) {
                quotedPlan = nil
                pendingQuality = nil
            }
        } message: {
            Text(quoteMessage)
        }
        .confirmationDialog(
            "Remove audio converted at other qualities?",
            isPresented: Binding(
                get: { cleanupOffer != nil },
                set: { if !$0 { cleanupOffer = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { Task { await runCleanup() } }
            Button("Keep", role: .cancel) { cleanupOffer = nil }
        } message: {
            Text(
                "Converting again later would repeat the work. Keeping it costs disk space "
                + "inside Aro; nothing in your library is affected either way."
            )
        }
        .overlay {
            if quoting {
                ProgressView("Checking how long this will take…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var streamBinding: Binding<StreamQuality> {
        Binding(
            get: { preferences.streamQuality },
            set: { requestChange(to: $0, isStream: true) }
        )
    }

    private var downloadBinding: Binding<StreamQuality> {
        Binding(
            get: { preferences.downloadQuality },
            set: { requestChange(to: $0, isStream: false) }
        )
    }

    /// Moving *down* the ladder needs audio that may not exist yet, so the hub is asked what
    /// that would cost before anything is committed to. Moving back up needs nothing new —
    /// the original files are always there — so it applies immediately and only offers to
    /// reclaim the space afterwards.
    private func requestChange(to quality: StreamQuality, isStream: Bool) {
        let previous = isStream ? preferences.streamQuality : preferences.downloadQuality
        guard quality != previous else { return }
        if isStream {
            preferences.streamQuality = quality
        } else {
            preferences.downloadQuality = quality
        }
        guard quality != .original else {
            offerCleanupIfWorthwhile()
            return
        }
        guard let plan else { return }
        pendingQuality = quality
        quoting = true
        Task {
            let quote = await plan(quality)
            quoting = false
            // Nothing outstanding means the hub already holds every track at this quality.
            guard let quote, quote.tracksPending > 0 else {
                statusMessage = quote == nil
                    ? "Could not reach the library to plan the conversion."
                    : "Already converted — nothing new to do."
                pendingQuality = nil
                return
            }
            quotedPlan = quote
        }
    }

    private func beginConversion() async {
        guard let start, let quality = pendingQuality else { return }
        quotedPlan = nil
        pendingQuality = nil
        job = await start(quality)
        guard let started = job else {
            statusMessage = "Could not start the conversion."
            return
        }
        await follow(started.jobID)
    }

    /// Polls rather than streams: a conversion runs for minutes to hours, and a dropped
    /// connection mid-job shouldn't lose the progress display.
    private func follow(_ jobID: UUID) async {
        guard let progress else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard let latest = await progress(jobID) else { return }
            job = latest
            if latest.state != .running && latest.state != .pending {
                statusMessage = latest.state == .completed
                    ? "Conversion finished."
                    : "Conversion stopped: \(latest.error ?? "unknown reason")."
                await refreshUsage()
                return
            }
        }
    }

    private func offerCleanupIfWorthwhile() {
        Task {
            await refreshUsage()
            let keep = preferences.streamQuality
            let reclaimable = storedUsage.contains { $0.quality != keep.rawValue }
            if reclaimable {
                cleanupOffer = keep
            }
        }
    }

    private func runCleanup() async {
        guard let cleanup, let keep = cleanupOffer else { return }
        cleanupOffer = nil
        guard let result = await cleanup(keep) else {
            statusMessage = "Could not remove the converted audio."
            return
        }
        statusMessage = "Removed \(result.removed) converted files, freeing \(byteText(result.freedBytes))."
        await refreshUsage()
    }

    private func refreshUsage() async {
        guard let usage else { return }
        storedUsage = await usage()
    }

    private var quoteTitle: String {
        guard let pendingQuality else { return "Convert Library" }
        return "Convert to \(pendingQuality.title)?"
    }

    private var quoteMessage: String {
        guard let quotedPlan else { return "" }
        return "\(quotedPlan.tracksPending) tracks need converting — about "
            + "\(durationText(quotedPlan.estimatedSeconds)) on this library's server, using "
            + "about \(byteText(quotedPlan.estimatedBytes)) of space inside Aro. "
            + "You can keep listening while it runs."
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
