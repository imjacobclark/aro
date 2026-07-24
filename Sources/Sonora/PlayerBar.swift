import SwiftUI

struct PlayerBar: View {
    @Bindable var playback: PlaybackController

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var isShowingOutputStatus = false

    var body: some View {
        HStack(spacing: 10) {
            songInformation
                .frame(width: 128, alignment: .leading)

            VStack(spacing: 4) {
                transportControls
                timeline
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1)

            outputControl
                .frame(width: 64)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minWidth: 500, minHeight: 68)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .onChange(of: playback.elapsedTime) { _, newValue in
            guard !isScrubbing else {
                return
            }
            scrubTime = newValue
        }
        .onChange(of: playback.currentSong?.id) {
            scrubTime = playback.elapsedTime
        }
    }

    private var songInformation: some View {
        VStack(alignment: .leading, spacing: 3) {
            MarqueeText(playback.currentSong?.title ?? "Not Playing")
                .id(playback.currentSong?.id)
                .frame(height: 18)
                .accessibilityLabel(
                    playback.currentSong?.title ?? "Not Playing"
                )

            if let errorMessage = playback.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .help(errorMessage)
                    .lineLimit(1)
            } else {
                Text(playback.currentSong?.artist ?? "Choose a song to begin")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var transportControls: some View {
        HStack(spacing: 11) {
            Button(action: playback.previous) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(!playback.canGoPrevious)
            .help("Previous")
            .accessibilityLabel("Previous")

            Button(action: playback.togglePlayPause) {
                Group {
                    if playback.state == .loading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(
                            systemName: playback.isPlaying
                                ? "pause.fill"
                                : "play.fill"
                        )
                        .font(.system(size: 11, weight: .semibold))
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(!playback.canTogglePlayback || playback.state == .loading)
            .help(playback.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Button(action: playback.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(!playback.canGoNext)
            .help("Next")
            .accessibilityLabel("Next")
        }
    }

    private var timeline: some View {
        HStack(spacing: 6) {
            Text(formatTime(displayedTime))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 48, alignment: .trailing)

            Slider(
                value: $scrubTime,
                in: 0...max(playback.duration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        playback.seek(to: scrubTime)
                    }
                }
            )
            .disabled(playback.currentSong == nil || playback.duration <= 0)
            .accessibilityLabel("Playback position")

            Text("-\(formatTime(max(playback.duration - displayedTime, 0)))")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 52, alignment: .leading)
        }
        .font(SonoraFont.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeSymbol)
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { playback.volume },
                    set: { newValue in
                        playback.setVolume(newValue)
                    }
                ),
                in: 0...1
            )
            .accessibilityLabel("Volume")
        }
    }

    @ViewBuilder
    private var outputControl: some View {
        if playback.outputStatus.mode == .bitPerfect {
            VStack(spacing: 2) {
                Button {
                    isShowingOutputStatus.toggle()
                } label: {
                    Image(
                        systemName: playback.outputStatus.isExclusive
                            ? "lock.fill"
                            : "waveform.badge.magnifyingglass"
                    )
                    .frame(width: 14, height: 14)
                }
                .frame(width: 30, height: 30)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help(playback.outputStatus.fidelityLabel)
                .popover(isPresented: $isShowingOutputStatus) {
                    outputStatusPopover
                }

                Text(outputFormatLabel)
                    .font(SonoraFont.caption2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        } else {
            volumeControl
        }
    }

    private var outputFormatLabel: String {
        playback.outputStatus.formatLabel
            .components(separatedBy: " · ")
            .first
            ?? "Native"
    }

    private var outputStatusPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(
                        .tint.opacity(0.12),
                        in: Circle()
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio Signal Path")
                        .font(SonoraFont.headline)
                    Text(playback.outputStatus.fidelityLabel)
                        .font(SonoraFont.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(signalBadge)
                    .font(
                        SonoraFont.textStyle(
                            .caption2,
                            weight: .bold
                        )
                    )
                    .foregroundStyle(signalBadgeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        signalBadgeColor.opacity(0.12),
                        in: Capsule()
                    )
            }

            VStack(spacing: 0) {
                ForEach(Array(signalChain.enumerated()), id: \.element.id) {
                    index, step in
                    SignalChainRow(step: step)
                    if index < signalChain.count - 1 {
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

            if let warning = playback.outputStatus.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(SonoraFont.callout)
                    .foregroundStyle(SonoraTheme.amber)
            }
        }
        .padding(16)
        .frame(width: 370)
    }

    private var signalChain: [SignalChainStep] {
        let status = playback.outputStatus
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
        let processing: String
        if status.mode == .bitPerfect {
            processing = "No DSP · Unity gain"
        } else {
            processing = String(
                format: "LUFS normalization · %+.1f dB",
                status.appliedGainDecibels
            )
        }
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

    private var signalBadge: String {
        if playback.outputStatus.mode == .normalized {
            return "DSP"
        }
        return playback.outputStatus.isExclusive ? "Bit Perfect" : "Native"
    }

    private var signalBadgeColor: Color {
        playback.outputStatus.mode == .bitPerfect
            ? .green
            : SonoraTheme.amber
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

    private var displayedTime: TimeInterval {
        isScrubbing ? scrubTime : playback.elapsedTime
    }

    private var volumeSymbol: String {
        switch playback.volume {
        case 0:
            return "speaker.slash.fill"
        case 0..<0.34:
            return "speaker.wave.1.fill"
        case 0.34..<0.67:
            return "speaker.wave.2.fill"
        default:
            return "speaker.wave.3.fill"
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else {
            return "0:00"
        }

        let totalSeconds = Int(time.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct SignalChainStep: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

private struct SignalChainRow: View {
    let step: SignalChainStep

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: step.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(
                    .tint.opacity(0.1),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(SonoraFont.textStyle(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(step.detail)
                    .font(SonoraFont.subheadline)
                    .lineLimit(1)
                    .help(step.detail)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct MarqueeText: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        GeometryReader { geometry in
            Text(text)
                .font(SonoraFont.headline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
                .background {
                    GeometryReader { textGeometry in
                        Color.clear
                            .onAppear {
                                textWidth = textGeometry.size.width
                            }
                            .onChange(of: textGeometry.size.width) {
                                textWidth = textGeometry.size.width
                            }
                    }
                }
                .onAppear {
                    containerWidth = geometry.size.width
                }
                .onChange(of: geometry.size.width) {
                    containerWidth = geometry.size.width
                }
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.035),
                    .init(color: .white, location: 0.965),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .help(text)
        .task(id: MarqueeMetrics(textWidth: textWidth, containerWidth: containerWidth)) {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                offset = 0
            }

            let overflow = textWidth - containerWidth
            guard overflow > 0, !reduceMotion else {
                return
            }

            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else {
                return
            }

            let travelDistance = overflow + 12
            let duration = max(Double(travelDistance) / 28, 2)
            withAnimation(
                .linear(duration: duration)
                    .delay(0.8)
                    .repeatForever(autoreverses: true)
            ) {
                offset = -travelDistance
            }
        }
    }
}

private struct MarqueeMetrics: Equatable {
    let textWidth: CGFloat
    let containerWidth: CGFloat
}
