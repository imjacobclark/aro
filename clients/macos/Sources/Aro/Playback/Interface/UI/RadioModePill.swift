import SwiftUI

/// "Radio on", as a pill in the player bar.
///
/// A station and a hand-picked queue behave identically, so the only way to know which one
/// you are in is to be told — and an icon swap alone was too quiet to notice. A labelled
/// pill says it outright, and the motion is what makes it read as *live* rather than as
/// another piece of chrome: the mast's arcs emanate outward on a loop, and the whole pill
/// breathes underneath them.
///
/// Two separate animations on purpose. The symbol effect is quick and directional, so it
/// looks like transmission; the breath is slow and gentle, so peripheral vision registers
/// something alive without the eye being dragged back to it every second. Matching their
/// speeds made the whole thing pulse like an alert, which is the wrong idea entirely —
/// nothing here is wrong, it is just on.
struct RadioModePill: View {
    @State private var isBreathing = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(AroFont.scaled(11, relativeTo: .caption, weight: .semibold))
                .symbolEffect(
                    .variableColor.iterative.reversing,
                    options: .repeating
                )
            Text("Radio on")
                .font(AroFont.scaled(11, relativeTo: .caption, weight: .semibold))
                .fixedSize()
        }
        .foregroundStyle(AroTheme.radioGlow)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(AroTheme.radioGlow.opacity(isBreathing ? 0.20 : 0.11))
        )
        .overlay(
            Capsule().strokeBorder(
                AroTheme.radioGlow.opacity(isBreathing ? 0.55 : 0.30),
                lineWidth: 1
            )
        )
        .shadow(
            color: AroTheme.radioGlow.opacity(isBreathing ? 0.45 : 0.12),
            radius: isBreathing ? 7 : 2
        )
        // Started here rather than in the parent so the breath begins fresh each time a
        // station starts, and stops existing when one ends — the pill is only ever on
        // screen while it is true.
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.9).repeatForever(autoreverses: true)
            ) {
                isBreathing = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Radio on. Playback queue")
    }
}
