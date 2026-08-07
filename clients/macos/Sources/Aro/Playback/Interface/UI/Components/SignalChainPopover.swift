import SwiftUI
import AroCommon

struct SignalChainPopover: View {
    let status: PlaybackOutputStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            chain

            if let warning = status.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(AroFont.callout)
                    .foregroundStyle(AroTheme.amber)
            }
        }
        .padding(16)
        .frame(width: 370)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Audio Signal Path")
                    .font(AroFont.headline)
                Text(status.fidelityLabel)
                    .font(AroFont.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(badge)
                .font(AroFont.textStyle(.caption2, weight: .bold))
                .foregroundStyle(badgeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(badgeColor.opacity(0.12), in: Capsule())
        }
    }

    private var chain: some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) {
                index, step in
                SignalChainRow(step: step)
                if index < steps.count - 1 {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 17)
                        .padding(.vertical, 2)
                }
            }
        }
        .padding(10)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.055), lineWidth: 0.7)
        }
    }

    private var steps: [SignalChainStep] {
        let sourceFormat = formatDescription(
            codec: displayCodec(status.sourceCodec),
            bitDepth: status.sourceBitDepth,
            sampleRate: status.sourceSampleRate
        )
        let decodedFormat = formatDescription(
            codec: "PCM",
            bitDepth: status.sourceBitDepth,
            sampleRate: status.sourceSampleRate
        )
        let processing = status.mode == .bitPerfect
            ? "No DSP · Unity gain"
            : String(
                format: "LUFS normalization · %+.1f dB",
                status.appliedGainDecibels
            )
        let access = status.isExclusive
            ? "Exclusive hardware access"
            : "Shared system output"
        let device = status.formatLabel.isEmpty
            ? status.deviceName
            : "\(status.deviceName) · \(status.formatLabel)"

        return [
            SignalChainStep(
                icon: "waveform",
                title: "Source",
                detail: sourceFormat
            ),
            SignalChainStep(
                icon: "waveform.path",
                title: "Decoded",
                detail: decodedFormat
            ),
            SignalChainStep(
                icon: "slider.horizontal.3",
                title: "Processing",
                detail: processing
            ),
            SignalChainStep(
                icon: status.isExclusive ? "lock.fill" : "person.2",
                title: "Output mode",
                detail: access
            ),
            SignalChainStep(
                icon: "hifispeaker.fill",
                title: "Hardware",
                detail: device
            )
        ]
    }

    private var badge: String {
        if status.mode == .normalized {
            return "DSP"
        }
        return status.isExclusive ? "Bit Perfect" : "Native"
    }

    private var badgeColor: Color {
        status.mode == .bitPerfect ? .green : AroTheme.amber
    }

    private func displayCodec(_ codec: String?) -> String {
        guard let codec, !codec.isEmpty else {
            return "Audio"
        }
        let value = codec.lowercased()
        if value.contains("flac") || value.contains("free lossless") {
            return "FLAC"
        }
        if value.contains("apple lossless") || value.contains("alac") {
            return "ALAC"
        }
        if value.contains("aac") {
            return "AAC"
        }
        if value.contains("mpeg") || value.contains("mp3") {
            return "MP3"
        }
        if value.contains("wave") || value.contains("wav") {
            return "WAV"
        }
        if value.contains("aiff") {
            return "AIFF"
        }
        if value.contains("vorbis") || value.contains("ogg") {
            return "OGG Vorbis"
        }
        return codec
    }

    private func formatDescription(
        codec: String,
        bitDepth: Int?,
        sampleRate: Double?
    ) -> String {
        var parts = [codec]
        if let bitDepth {
            parts.append("\(bitDepth)-bit")
        }
        if let sampleRate {
            let rate = (sampleRate / 1_000).formatted(
                .number.precision(.fractionLength(0...1))
            )
            parts.append("\(rate) kHz")
        }
        return parts.joined(separator: " · ")
    }
}
