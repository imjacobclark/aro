import CoreText
import SwiftUI

enum SonoraFont {
    enum Weight {
        case regular
        case semibold
        case bold
    }

    static let body = textStyle(.body)
    static let callout = textStyle(.callout)
    static let caption = textStyle(.caption)
    static let caption2 = textStyle(.caption2)
    static let footnote = textStyle(.footnote)
    static let headline = textStyle(.headline, weight: .semibold)
    static let subheadline = textStyle(.subheadline)
    static let largeTitle = textStyle(.largeTitle, weight: .bold)

    static func textStyle(
        _ style: Font.TextStyle,
        weight: Weight = .regular
    ) -> Font {
        .custom(
            fontName(for: weight),
            size: pointSize(for: style),
            relativeTo: style
        )
    }

    static func fixed(_ size: CGFloat, weight: Weight = .regular) -> Font {
        .custom(fontName(for: weight), fixedSize: size)
    }

    static func register() {
        guard let url = bundledFontURL() else {
            assertionFailure("Bundled Montserrat font is missing")
            return
        }

        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(
            url as CFURL,
            .process,
            &error
        )
    }

    private static func bundledFontURL() -> URL? {
        if let appURL = Bundle.main.url(
            forResource: "Montserrat-Variable",
            withExtension: "ttf"
        ) {
            return appURL
        }

        return Bundle.module.url(
            forResource: "Montserrat-Variable",
            withExtension: "ttf",
            subdirectory: "Fonts"
        ) ?? Bundle.module.url(
            forResource: "Montserrat-Variable",
            withExtension: "ttf"
        )
    }

    private static func fontName(for weight: Weight) -> String {
        switch weight {
        case .regular:
            "Montserrat-Regular"
        case .semibold:
            "Montserrat-SemiBold"
        case .bold:
            "Montserrat-Bold"
        }
    }

    private static func pointSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle:
            26
        case .title:
            22
        case .title2:
            17
        case .title3:
            15
        case .headline:
            13
        case .subheadline, .callout:
            12
        case .caption:
            11
        case .caption2, .footnote:
            10
        default:
            13
        }
    }
}
