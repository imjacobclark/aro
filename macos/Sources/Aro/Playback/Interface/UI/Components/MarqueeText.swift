import AroCommon

import SwiftUI

struct MarqueeText: View {
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
                .font(AroFont.headline)
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
        .task(
            id: MarqueeMetrics(
                textWidth: textWidth,
                containerWidth: containerWidth
            )
        ) {
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
