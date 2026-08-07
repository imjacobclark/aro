import AppKit
import SwiftUI

struct LibraryExportSession: Identifiable {
    let id = UUID()
    let exporter: AroLibraryExporter
}

struct ExportLibrarySheet: View {
    let session: LibraryExportSession

    @Environment(\.dismiss) private var dismiss
    @State private var destination: URL?
    @State private var progress: LibraryExportProgress?
    @State private var result: LibraryExportResult?
    @State private var errorMessage: String?
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Export Library")
                    .font(.largeTitle)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isExporting)
            }
            Text(
                "Aro downloads every active song and every recoverable recently removed song without changing a byte."
            )
            .foregroundStyle(.secondary)

            if let result {
                ContentUnavailableView {
                    Label("Export complete", systemImage: "checkmark.circle.fill")
                } description: {
                    Text(
                        "\(result.exportedTracks) songs downloaded and \(result.unchangedTracks) matching songs kept."
                    )
                } actions: {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            result.rootURL
                        ])
                    }
                }
            } else {
                GroupBox {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(destination?.path ?? "Choose a destination")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(
                                "The export will be written into a new aro-library folder."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Choose…", action: chooseDestination)
                            .disabled(isExporting)
                    }
                }
                if let progress {
                    ProgressView(
                        value: Double(progress.completedTracks),
                        total: Double(max(1, progress.totalTracks))
                    ) {
                        Text(progress.currentTrack)
                    } currentValueLabel: {
                        Text(
                            "\(progress.completedTracks) of \(progress.totalTracks)"
                        )
                    }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer()
                HStack {
                    Spacer()
                    Button("Export Library", action: startExport)
                        .buttonStyle(.borderedProminent)
                        .disabled(destination == nil || isExporting)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 620, height: sheetHeight)
    }

    private var sheetHeight: CGFloat {
        if result != nil || progress != nil || errorMessage != nil {
            return 440
        }
        return 330
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Where to Export Your Aro Library"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return }
        destination = panel.url
    }

    private func startExport() {
        guard let destination else { return }
        isExporting = true
        errorMessage = nil
        Task {
            do {
                result = try await session.exporter.export(
                    to: destination
                ) { update in
                    await MainActor.run {
                        progress = update
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }
}
