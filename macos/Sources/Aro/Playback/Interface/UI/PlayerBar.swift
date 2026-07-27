import AroCommon

import SwiftUI

@MainActor
struct PlayerBar: View {
    // These objects are observed through their @Observable accessors. PlayerBar
    // does not need projected bindings to any of them, and keeping plain strong
    // references avoids retaining @Bindable registrar state while a library
    // runtime is replaced.
    let playback: PlaybackController
    let preferences: PlaybackPreferences
    let deviceManager: AudioDeviceManager

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var isShowingOutputStatus = false
    @State private var isShowingRoutes = false

    var body: some View {
        HStack(spacing: 10) {
            songInformation
                .frame(width: 128, alignment: .leading)
                .layoutPriority(1)

            VStack(spacing: 4) {
                transportControls
                timeline
            }
            .frame(maxWidth: .infinity)

            outputControl
                .frame(width: 180)
                .layoutPriority(1)
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
            Button {
                playback.previous()
            } label: {
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

            Button {
                playback.togglePlayPause()
            } label: {
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

            Button {
                playback.next()
            } label: {
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
        .font(AroFont.caption)
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
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 2) {
                Button {
                    isShowingOutputStatus.toggle()
                } label: {
                    Image(
                        systemName: playback.outputStatus.transport.systemImageName
                    )
                    .frame(width: 14, height: 14)
                }
                .frame(width: 30, height: 30)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help(playback.outputStatus.fidelityLabel)
                .popover(isPresented: $isShowingOutputStatus) {
                    SignalChainPopover(status: playback.outputStatus)
                }

                Text(outputFormatLabel)
                    .font(AroFont.caption2)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 34)

            volumeControl
                .frame(width: 82, height: 30)
                .opacity(playback.outputStatus.mode == .bitPerfect ? 0.55 : 1)
                .disabled(playback.outputStatus.mode == .bitPerfect)
                .help(
                    playback.outputStatus.mode == .bitPerfect
                        ? "Volume is fixed at unity in Bit-Perfect mode"
                        : "Output volume"
                )

            Button {
                isShowingRoutes.toggle()
            } label: {
                Image(systemName: "chevron.up.circle")
                    .frame(width: 14, height: 14)
            }
            .frame(width: 30, height: 30)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .popover(isPresented: $isShowingRoutes) {
                OutputRoutePopover(
                    preferences: preferences,
                    deviceManager: deviceManager,
                    playback: playback
                )
            }
        }
    }

    private var outputFormatLabel: String {
        playback.outputStatus.formatLabel
            .components(separatedBy: " · ")
            .first
            ?? "Native"
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
