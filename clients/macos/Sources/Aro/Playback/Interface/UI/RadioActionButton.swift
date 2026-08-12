import SwiftUI

/// The control that starts a station, and then says it did.
///
/// Radio is offered from several places — an artist, a "More Like This" shelf — and each
/// one needs the same two states. Coming back to the artist you started a station from and
/// finding a button politely offering to start the thing already playing is the kind of
/// small dishonesty that makes an app feel like it isn't paying attention, so the control
/// that started it wears the same live pill the player bar does.
///
/// Both states are drawn here rather than leaning on `.bordered`, so the off state is
/// already pill-shaped and only the fill, colour and motion change when it comes on —
/// otherwise switching states re-shapes the control and it reads as two different buttons.
struct RadioActionButton: View {
    let isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            if isOn {
                RadioModePill()
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(AroFont.scaled(11, relativeTo: .caption, weight: .semibold))
                    Text("Radio")
                        .font(AroFont.scaled(11, relativeTo: .caption, weight: .semibold))
                        .fixedSize()
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(AroTheme.hairline, lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        // Nothing to do when it is already playing, but left enabled rather than disabled:
        // a greyed-out control reads as broken, and restarting a station you are already
        // on is harmless.
        .help(isOn ? "This station is playing" : "Play these as a station")
    }
}
