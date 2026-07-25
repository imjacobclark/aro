import SonoraCommon

import SwiftUI

struct ChillVisualizer: View {
    let levels: [Double]
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1 / 24,
                paused: !isActive || reduceMotion
            )
        ) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let rotation = reduceMotion ? 0 : time * 0.16

            Canvas { context, size in
                let side = min(size.width, size.height)
                let center = CGPoint(
                    x: size.width / 2,
                    y: size.height / 2
                )
                let quietLevel = isActive ? 0.04 : 0

                for radius in [side * 0.25, side * 0.38] {
                    let ring = Path(
                        ellipseIn: CGRect(
                            x: center.x - radius,
                            y: center.y - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                    )
                    context.stroke(
                        ring,
                        with: .color(.white.opacity(0.07)),
                        lineWidth: 0.7
                    )
                }

                var waveform = Path()
                let pointCount = 48

                for pointIndex in 0..<pointCount {
                    let angle = (Double(pointIndex) / Double(pointCount))
                        * .pi * 2
                        + rotation
                        - (.pi / 2)
                    let level = interpolatedLevel(
                        at: pointIndex,
                        pointCount: pointCount
                    )
                    let radialLevel = peakLevel * 0.72 + level * 0.28
                    let radius = side * 0.19
                        + max(radialLevel, quietLevel) * side * 0.23
                    let point = CGPoint(
                        x: center.x + cos(angle) * radius,
                        y: center.y + sin(angle) * radius
                    )

                    if pointIndex == 0 {
                        waveform.move(to: point)
                    } else {
                        waveform.addLine(to: point)
                    }

                    let rayStart = CGPoint(
                        x: center.x + cos(angle) * side * 0.13,
                        y: center.y + sin(angle) * side * 0.13
                    )
                    var ray = Path()
                    ray.move(to: rayStart)
                    ray.addLine(to: point)
                    context.stroke(
                        ray,
                        with: .color(
                            SonoraTheme.orbitColor(
                                at: Double(pointIndex)
                                    / Double(pointCount - 1)
                            )
                            .opacity(0.16 + radialLevel * 0.38)
                        ),
                        lineWidth: 0.65
                    )
                }
                waveform.closeSubpath()

                context.drawLayer { layer in
                    layer.addFilter(
                        .shadow(
                            color: SonoraTheme.coral.opacity(
                                isActive ? 0.38 : 0.1
                            ),
                            radius: 7
                        )
                    )
                    layer.fill(
                        waveform,
                        with: .linearGradient(
                            Gradient(
                                colors: [
                                    SonoraTheme.violet.opacity(0.58),
                                    SonoraTheme.coral.opacity(0.52),
                                    SonoraTheme.amber.opacity(0.55)
                                ]
                            ),
                            startPoint: CGPoint(
                                x: side * 0.16,
                                y: side * 0.16
                            ),
                            endPoint: CGPoint(
                                x: side * 0.84,
                                y: side * 0.84
                            )
                        )
                    )
                    layer.stroke(
                        waveform,
                        with: .color(
                            SonoraTheme.coral.opacity(isActive ? 0.88 : 0.3)
                        ),
                        lineWidth: 1.1
                    )
                }

                let coreSize = side * (0.09 + averageLevel * 0.07)
                let core = Path(
                    ellipseIn: CGRect(
                        x: center.x - coreSize / 2,
                        y: center.y - coreSize / 2,
                        width: coreSize,
                        height: coreSize
                    )
                )
                context.fill(
                    core,
                    with: .radialGradient(
                        Gradient(
                            colors: [
                                .white,
                                SonoraTheme.amber,
                                SonoraTheme.violet
                            ]
                        ),
                        center: center,
                        startRadius: 0,
                        endRadius: coreSize
                    )
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .glassEffect(
                .regular,
                in: Rectangle()
            )
            .overlay {
                Rectangle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.18),
                                SonoraTheme.coral.opacity(0.14),
                                SonoraTheme.violet.opacity(0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.7
                    )
            }
            .opacity(isActive ? 1 : 0.52)
            .animation(
                reduceMotion
                    ? nil
                    : .smooth(duration: 0.14, extraBounce: 0.04),
                value: levels
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.25),
                value: isActive
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback visualizer")
        .accessibilityValue(isActive ? "Playing" : "Idle")
    }

    private var averageLevel: Double {
        guard !levels.isEmpty else {
            return 0
        }
        return levels.reduce(0, +) / Double(levels.count)
    }

    private var peakLevel: Double {
        levels.max() ?? 0
    }

    private func interpolatedLevel(
        at pointIndex: Int,
        pointCount: Int
    ) -> Double {
        guard !levels.isEmpty else {
            return 0
        }

        let quadrantPointCount = max(pointCount / 4, 1)
        let pointInQuadrant = pointIndex % quadrantPointCount
        let position = Double(pointInQuadrant) * Double(levels.count)
            / Double(quadrantPointCount)
        let lowerIndex = Int(position) % levels.count
        let upperIndex = (lowerIndex + 1) % levels.count
        let fraction = position - floor(position)
        return levels[lowerIndex] * (1 - fraction)
            + levels[upperIndex] * fraction
    }
}
