import AroCommon
import SwiftUI

@MainActor
struct PlayerBar: View {
    let playback: PlaybackController
    let preferences: PlaybackPreferences
    let deviceManager: AudioDeviceManager
    let setFavourite: (Song, Bool) async throws -> Void

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var displayedVolume: Double = 1
    @State private var isShowingOutputStatus = false
    @State private var isShowingRoutes = false
    @State private var isShowingQueue = false
    @State private var favouriteError: String?

    var body: some View {
        HStack(spacing: 14) {
            nowPlaying
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 250)
                .layoutPriority(2)

            transportControls
                .frame(width: 176)

            timeline
                .frame(minWidth: 135, maxWidth: .infinity)
                .layoutPriority(1)

            outputControls
                .frame(width: 198)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.28))
        .clipShape(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.11))
        }
        .shadow(color: .black.opacity(0.09), radius: 14, y: 5)
        .onChange(of: playback.elapsedTime) { _, newValue in
            guard !isScrubbing else { return }
            scrubTime = newValue
        }
        .onChange(of: playback.currentSong?.id) {
            scrubTime = playback.elapsedTime
        }
        .onChange(of: playback.volume) { _, newValue in
            guard displayedVolume != newValue else { return }
            displayedVolume = newValue
        }
        .onChange(of: displayedVolume) { _, newValue in
            guard playback.volume != newValue else { return }
            playback.setVolume(newValue)
        }
        .task(id: ObjectIdentifier(playback)) {
            displayedVolume = playback.volume
        }
        .onDisappear {
            isShowingOutputStatus = false
            isShowingRoutes = false
            isShowingQueue = false
        }
        .alert(
            "Unable to Update Favourite",
            isPresented: Binding(
                get: { favouriteError != nil },
                set: { if !$0 { favouriteError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(favouriteError ?? "Unknown error")
        }
    }

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            AlbumArtworkView(data: playback.currentSong?.artworkData, maxDimension: 66)
                .frame(width: 66, height: 66)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(playback.currentSong?.title ?? "Not Playing")
                        .font(AroFont.fixed(14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(playback.currentSong?.title ?? "Not Playing")

                    Spacer(minLength: 0)

                    Button(action: toggleFavourite) {
                        Image(
                            systemName:
                                playback.currentSong?.isFavourite == true
                                    ? "heart.fill"
                                    : "heart"
                        )
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            playback.currentSong?.isFavourite == true
                                ? AroTheme.violet
                                : Color.secondary
                        )
                        .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(playback.currentSong == nil)
                    .help(
                        playback.currentSong?.isFavourite == true
                            ? "Remove from favourites"
                            : "Add to favourites"
                    )
                    .accessibilityLabel(
                        playback.currentSong?.isFavourite == true
                            ? "Remove from favourites"
                            : "Add to favourites"
                    )
                }

                Text(artistAndAlbum)
                    .font(AroFont.fixed(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 5) {
                    if playback.state == .buffering {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Buffering")
                    } else if let error = playback.errorMessage {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error)
                            .help(error)
                    } else {
                        Text(sourceFormat)
                    }
                }
                .font(AroFont.fixed(10))
                .foregroundStyle(
                    playback.errorMessage == nil
                        ? Color.secondary
                        : Color.red
                )
                .lineLimit(1)
                .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 10) {
            PlayerControlButton(
                systemImage: "shuffle",
                label: playback.isShuffleEnabled
                    ? "Disable Shuffle"
                    : "Enable Shuffle",
                isActive: playback.isShuffleEnabled,
                action: playback.toggleShuffle
            )

            PlayerControlButton(
                systemImage: "backward.fill",
                label: "Previous",
                isDisabled: !playback.canGoPrevious,
                action: playback.previous
            )

            Button {
                playback.togglePlayPause()
            } label: {
                Group {
                    if playback.state == .loading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(
                            systemName: playback.isPlaying
                                ? "pause.fill"
                                : "play.fill"
                        )
                        .font(.system(size: 17, weight: .semibold))
                        .offset(x: playback.isPlaying ? 0 : 1)
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(AroTheme.violet, in: Circle())
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(
                !playback.canTogglePlayback || playback.state == .loading
            )
            .opacity(playback.canTogglePlayback ? 1 : 0.48)
            .shadow(
                color: AroTheme.violet.opacity(0.24),
                radius: 6,
                y: 2
            )
            .help(playback.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            PlayerControlButton(
                systemImage: "forward.fill",
                label: "Next",
                isDisabled: !playback.canGoNext,
                action: playback.next
            )

            PlayerControlButton(
                systemImage: repeatSystemImage,
                label: playback.repeatMode.displayName,
                isActive: playback.repeatMode != .off,
                action: playback.cycleRepeatMode
            )
        }
    }

    private var timeline: some View {
        HStack(spacing: 7) {
            Text(formatTime(displayedTime))
                .frame(width: 38, alignment: .trailing)

            ZStack {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.secondary.opacity(0.16))
                        .frame(
                            width: proxy.size.width
                                * min(max(playback.bufferedFraction, 0), 1),
                            height: 3
                        )
                        .frame(maxHeight: .infinity, alignment: .center)
                }
                .allowsHitTesting(false)

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
                .tint(AroTheme.violet)
            }
            .frame(minHeight: 20)
            .disabled(playback.currentSong == nil || playback.duration <= 0)
            .accessibilityLabel("Playback position")
            .accessibilityValue(
                "\(formatTime(displayedTime)) of "
                    + formatTime(playback.duration)
            )

            Text(formatTime(playback.duration))
                .frame(width: 38, alignment: .leading)
        }
        .font(AroFont.fixed(10))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var outputControls: some View {
        HStack(spacing: 7) {
            Button {
                isShowingOutputStatus.toggle()
            } label: {
                Image(
                    systemName:
                        playback.state == .playing
                            || playback.state == .buffering
                            ? "waveform"
                            : playback.outputStatus.transport.systemImageName
                )
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    playback.isPlaying
                        ? AroTheme.violet
                        : Color.secondary
                )
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(playback.outputStatus.fidelityLabel)
            .popover(isPresented: $isShowingOutputStatus) {
                SignalChainPopover(status: playback.outputStatus)
            }

            Button {
                isShowingRoutes.toggle()
            } label: {
                HStack(spacing: 4) {
                    // The live system device, not the engine's last-recorded route. The
                    // engine only writes a name while verifying a route, so before anything
                    // had played this showed the literal placeholder "System Default" no
                    // matter which device was actually selected.
                    Text(deviceManager.defaultDevice?.name
                        ?? playback.outputStatus.deviceName)
                        .font(AroFont.fixed(10, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .frame(width: 68, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose audio output")
            .accessibilityLabel(
                "Audio output, \(playback.outputStatus.deviceName)"
            )
            .popover(isPresented: $isShowingRoutes) {
                OutputRoutePopover(
                    preferences: preferences,
                    deviceManager: deviceManager,
                    playback: playback
                )
            }

            HStack(spacing: 4) {
                Image(systemName: volumeSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: $displayedVolume, in: 0...1)
                    .accessibilityLabel("Volume")
            }
            .frame(width: 64)
            .opacity(playback.effectiveMode == .bitPerfect ? 0.5 : 1)
            .disabled(playback.effectiveMode == .bitPerfect)
            .help(
                playback.effectiveMode == .bitPerfect
                    ? "Volume is fixed in Bit-Perfect mode: software gain would stop the output being bit-exact"
                    : "Output volume"
            )

            Button {
                isShowingQueue.toggle()
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(playback.queue.isEmpty)
            .help("Queue")
            .accessibilityLabel("Playback queue")
            .popover(isPresented: $isShowingQueue, arrowEdge: .bottom) {
                PlaybackQueuePopover(playback: playback)
            }
        }
    }

    private var artistAndAlbum: String {
        guard let song = playback.currentSong else {
            return "Choose a song to begin"
        }
        if let album = song.album, !album.isEmpty {
            return "\(song.artist) · \(album)"
        }
        return song.artist
    }

    private var sourceFormat: String {
        guard let properties = playback.currentSong?.audioProperties else {
            return "Audio format unavailable"
        }
        var parts = [properties.codec.uppercased()]
        if let sampleRate = properties.sampleRate {
            parts.append(
                (sampleRate / 1_000).formatted(
                    .number.precision(.fractionLength(0...1))
                ) + " kHz"
            )
        }
        if let bitDepth = properties.bitDepth {
            parts.append("\(bitDepth) bit")
        }
        return parts.joined(separator: " · ")
    }

    private var repeatSystemImage: String {
        playback.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private var displayedTime: TimeInterval {
        isScrubbing ? scrubTime : playback.elapsedTime
    }

    private var volumeSymbol: String {
        switch displayedVolume {
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

    private func toggleFavourite() {
        guard let song = playback.currentSong else { return }
        Task {
            do {
                try await setFavourite(song, !song.isFavourite)
            } catch {
                favouriteError = error.localizedDescription
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
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

private struct PlayerControlButton: View {
    let systemImage: String
    let label: String
    var isActive = false
    var isDisabled = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? AroTheme.violet : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    isHovering
                        ? Color.primary.opacity(0.065)
                        : Color.clear,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct PlaybackQueuePopover: View {
    let playback: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up Next")
                .font(AroFont.fixed(16, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            Divider()

            if playback.queue.isEmpty {
                Text("The queue is empty.")
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(
                            Array(playback.queue.enumerated()),
                            id: \.element.id
                        ) { index, song in
                            Button {
                                playback.playQueuedSong(at: index)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(
                                        systemName:
                                            playback.currentIndex == index
                                                ? "speaker.wave.2.fill"
                                                : "music.note"
                                    )
                                    .font(.system(size: 11))
                                    .foregroundStyle(
                                        playback.currentIndex == index
                                            ? AroTheme.violet
                                            : Color.secondary
                                    )
                                    .frame(width: 16)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(song.title)
                                            .font(
                                                AroFont.fixed(
                                                    12,
                                                    weight: .semibold
                                                )
                                            )
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(song.artist)
                                            .font(AroFont.fixed(10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Text(song.formattedDuration)
                                        .font(AroFont.fixed(10))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    playback.currentIndex == index
                                        ? AroTheme.selectedTint
                                        : Color.clear,
                                    in: RoundedRectangle(
                                        cornerRadius: 7,
                                        style: .continuous
                                    )
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(
                                playback.currentIndex == index
                                    ? .isSelected
                                    : []
                            )
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: 320, height: 360)
    }
}
