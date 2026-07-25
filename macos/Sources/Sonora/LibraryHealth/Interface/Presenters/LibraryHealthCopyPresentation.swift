import SonoraCommon

import Foundation

struct LibraryHealthCopyPresentation {
    let url: URL
    let fileName: String
    let directoryPath: String
    let formatLabel: String
    let fileSizeLabel: String

    init(copy: LibraryHealthCopy) {
        let url = URL(fileURLWithPath: copy.path)
        self.url = url
        fileName = url.lastPathComponent
        directoryPath = url.deletingLastPathComponent().path
        formatLabel = Self.formatLabel(for: copy)
        fileSizeLabel = ByteCountFormatter.string(
            fromByteCount: copy.fileSizeBytes,
            countStyle: .file
        )
    }

    private static func formatLabel(
        for copy: LibraryHealthCopy
    ) -> String {
        var parts = [copy.codec.uppercased()]
        if let bitDepth = copy.bitDepth {
            parts.append("\(bitDepth)-bit")
        }
        if let sampleRate = copy.sampleRate {
            let rate = (sampleRate / 1_000).formatted(
                .number.precision(.fractionLength(0...1))
            )
            parts.append("\(rate) kHz")
        } else if let bitrate = copy.bitrate {
            parts.append("\(Int(bitrate / 1_000)) kbps")
        }
        return parts.joined(separator: " · ")
    }
}
