import AroCommon

import SwiftUI

/// A calm, ambient spectrum wave used as the floating playback visualizer.
///
/// `spectrum` is a small set of normalized (0...1) band levels, already
/// smoothed upstream by the playback engine. This view owns none of that
/// processing — it only resamples, blends, and animates the values for
/// display via ``GradientWaveAnimator``.
struct GradientWaveVisualizer: View {
    let spectrum: [Double]
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animator = GradientWaveAnimator(barCount: GradientWaveVisualizer.barCount)

    private static let barCount = 48

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1 / 60,
                paused: !isPlaying
            )
        ) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let bars = animator.advance(
                spectrum: spectrum,
                time: time,
                isPlaying: isPlaying,
                reduceMotion: reduceMotion
            )

            Canvas { context, size in
                draw(bars: bars, context: &context, size: size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback visualizer")
        .accessibilityValue(isPlaying ? "Playing" : "Idle")
        .allowsHitTesting(false)
    }

    private func draw(
        bars: [Double],
        context: inout GraphicsContext,
        size: CGSize
    ) {
        guard bars.count > 1 else {
            return
        }

        let horizontalInset: CGFloat = 2
        let activeWidth = size.width - horizontalInset * 2
        let leftInset = horizontalInset
        let spacing = activeWidth / CGFloat(bars.count - 1)
        let baselineY = size.height * 0.82
        let maxBarHeight = size.height * 0.35
        let minBarHeight: CGFloat = 3
        let barWidth: CGFloat = 2.5

        var wavePath = Path()
        var reflectionPath = Path()

        for (index, value) in bars.enumerated() {
            let x = leftInset + CGFloat(index) * spacing
            let height = minBarHeight + CGFloat(value) * maxBarHeight

            wavePath.move(to: CGPoint(x: x, y: baselineY))
            wavePath.addLine(to: CGPoint(x: x, y: baselineY - height))

            let reflectionHeight = height * 0.38
            reflectionPath.move(to: CGPoint(x: x, y: baselineY))
            reflectionPath.addLine(to: CGPoint(x: x, y: baselineY + reflectionHeight))
        }

        let waveGradient = GraphicsContext.Shading.linearGradient(
            Gradient(colors: (0..<bars.count).map {
                AroTheme.orbitColor(at: Double($0) / Double(bars.count - 1))
            }),
            startPoint: CGPoint(x: leftInset, y: baselineY),
            endPoint: CGPoint(x: leftInset + activeWidth, y: baselineY)
        )

        context.drawLayer { layer in
            layer.opacity = 0.22
            layer.stroke(
                reflectionPath,
                with: waveGradient,
                style: StrokeStyle(lineWidth: barWidth, lineCap: .round)
            )
            layer.addFilter(.blur(radius: 1.2))
        }

        context.drawLayer { layer in
            layer.addFilter(
                .shadow(color: AroTheme.coral.opacity(0.32), radius: 6)
            )
            layer.stroke(
                wavePath,
                with: waveGradient,
                style: StrokeStyle(lineWidth: barWidth, lineCap: .round)
            )
        }
    }
}

/// Turns a handful of raw band levels into a wide, continuous wave and
/// carries the per-bar animation state (attack/release, drift, breathing)
/// between frames. Kept separate from the view so the view stays a pure
/// function of its inputs; kept separate from audio capture and playback
/// state so it only ever deals in normalized display values.
@MainActor
final class GradientWaveAnimator {
    private var displayed: [Double]
    private let barCount: Int

    init(barCount: Int) {
        self.barCount = barCount
        displayed = (0..<barCount).map {
            GradientWaveAnimator.baseShape(at: Double($0) / Double(barCount - 1)) * 0.22
        }
    }

    func advance(
        spectrum: [Double],
        time: Double,
        isPlaying: Bool,
        reduceMotion: Bool
    ) -> [Double] {
        guard isPlaying else {
            displayed = (0..<barCount).map {
                GradientWaveAnimator.baseShape(at: Double($0) / Double(barCount - 1)) * 0.22
            }
            return displayed
        }

        let resampled = Self.resample(spectrum, to: barCount)
        let smoothedSpectrum = Self.neighborAverage(resampled)
        let energy = smoothedSpectrum.max() ?? 0
        let isSilent = energy < 0.045
        let breathing = reduceMotion ? 1 : 0.92 + 0.08 * sin(time * 0.45)

        for index in 0..<barCount {
            let x = Double(index) / Double(barCount - 1)
            let base = Self.baseShape(at: x)
            var target = isSilent
                ? base * 0.3 * breathing
                : base * 0.35 + smoothedSpectrum[index] * 0.65

            if !reduceMotion {
                target += sin(time * 0.35 + x * 3.2) * 0.02
            }
            target = min(max(target, 0), 1)

            let rate = reduceMotion
                ? 0.5
                : (target > displayed[index] ? 0.32 : 0.09)
            displayed[index] += (target - displayed[index]) * rate
        }

        return displayed
    }

    /// The wave's resting silhouette: a moderate crest on the left, a deep
    /// dip near the centre, and a broader crest toward the right — kept
    /// asymmetric so the shape never reads as a mirrored equalizer.
    private static func baseShape(at x: Double) -> Double {
        let leftCrest = gaussianBump(x, center: 0.16, width: 0.14, height: 0.5)
        let centerDip = gaussianBump(x, center: 0.48, width: 0.16, height: 0.22)
        let rightCrest = gaussianBump(x, center: 0.72, width: 0.24, height: 0.85)
        let falloff = x > 0.86 ? max(1 - (x - 0.86) / 0.14, 0) : 1

        let value = (leftCrest + rightCrest - centerDip * 0.4) * falloff
        return min(max(value, 0.05), 1)
    }

    private static func gaussianBump(
        _ x: Double,
        center: Double,
        width: Double,
        height: Double
    ) -> Double {
        let distance = (x - center) / width
        return height * exp(-(distance * distance))
    }

    private static func resample(_ levels: [Double], to count: Int) -> [Double] {
        guard !levels.isEmpty else {
            return Array(repeating: 0, count: count)
        }
        guard levels.count > 1 else {
            return Array(repeating: levels[0], count: count)
        }

        return (0..<count).map { index in
            let position = Double(index) / Double(count - 1) * Double(levels.count - 1)
            let lowerIndex = Int(position)
            let upperIndex = min(lowerIndex + 1, levels.count - 1)
            let fraction = position - Double(lowerIndex)
            return levels[lowerIndex] * (1 - fraction) + levels[upperIndex] * fraction
        }
    }

    private static func neighborAverage(_ values: [Double]) -> [Double] {
        guard values.count > 2 else {
            return values
        }

        return values.indices.map { index in
            let lower = max(index - 2, 0)
            let upper = min(index + 2, values.count - 1)
            let slice = values[lower...upper]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }
}

struct GradientWaveVisualizer_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            GradientWavePreviewStage(
                spectrum: [0.7, 0.5, 0.85, 0.4, 0.3, 0.6, 0.9, 0.55, 0.35],
                isPlaying: true
            )
            .previewDisplayName("Playing")

            GradientWavePreviewStage(
                spectrum: [0.7, 0.5, 0.85, 0.4, 0.3, 0.6, 0.9, 0.55, 0.35],
                isPlaying: false
            )
            .previewDisplayName("Paused")

            GradientWavePreviewStage(
                spectrum: Array(repeating: 0, count: 9),
                isPlaying: true
            )
            .previewDisplayName("Idle / silent")

            // `accessibilityReduceMotion` is read-only on this SDK, so it
            // can't be forced from a preview — exercise it via System
            // Settings > Accessibility > Reduce Motion instead.
            GradientWavePreviewStage(
                spectrum: [0.7, 0.5, 0.85, 0.4, 0.3, 0.6, 0.9, 0.55, 0.35],
                isPlaying: true
            )
            .previewDisplayName("Reduce Motion (toggle system setting)")
        }
    }
}

private struct GradientWavePreviewStage: View {
    let spectrum: [Double]
    let isPlaying: Bool

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.07)
                .ignoresSafeArea()
            GradientWaveVisualizer(spectrum: spectrum, isPlaying: isPlaying)
                .frame(width: 230, height: 230)
        }
    }
}
