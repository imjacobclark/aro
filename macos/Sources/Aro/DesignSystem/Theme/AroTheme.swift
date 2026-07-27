import AroCommon

import SwiftUI

enum AroTheme {
    // Sampled from the app icon's orbital ring.
    static let violet = Color(
        red: 0.45,
        green: 0.35,
        blue: 0.88
    )
    static let coral = Color(
        red: 1.00,
        green: 0.45,
        blue: 0.51
    )
    static let amber = Color(
        red: 1.00,
        green: 0.69,
        blue: 0.23
    )
    static let navy = Color(
        red: 0.07,
        green: 0.09,
        blue: 0.20
    )

    static let orbitGradient = Gradient(
        colors: [violet, coral, amber]
    )

    static func orbitColor(at progress: Double) -> Color {
        let clamped = min(max(progress, 0), 1)
        if clamped < 0.5 {
            return interpolate(
                from: (0.45, 0.35, 0.88),
                to: (1.00, 0.45, 0.51),
                amount: clamped * 2
            )
        }

        return interpolate(
            from: (1.00, 0.45, 0.51),
            to: (1.00, 0.69, 0.23),
            amount: (clamped - 0.5) * 2
        )
    }

    private static func interpolate(
        from start: (Double, Double, Double),
        to end: (Double, Double, Double),
        amount: Double
    ) -> Color {
        Color(
            red: start.0 + (end.0 - start.0) * amount,
            green: start.1 + (end.1 - start.1) * amount,
            blue: start.2 + (end.2 - start.2) * amount
        )
    }
}
