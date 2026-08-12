#if canImport(XCTest)
import SwiftUI
import XCTest
@testable import Aro

/// Guards the property that makes the app usable at a larger system text size.
///
/// The accessibility work that landed before this gave VoiceOver something to read; text
/// scaling was the half that did not. Fixing it meant converting every `.system(size:)` and
/// `AroFont.fixed` used for *reading* over to sizes declared relative to a text style, which
/// is what SwiftUI grows when someone turns their text size up.
///
/// The risk now is the obvious one: the next person in a hurry reaches for `.system(size:)`
/// again, it looks right on their machine, and the app quietly stops scaling. These tests
/// read the source rather than the rendered view, because that regression is invisible at
/// the default size — which is the only size a screenshot ever shows.
final class TypographyScalingTests: XCTestCase {
    /// Views whose numeric sizes are deliberately fixed, with the reason.
    ///
    /// Each of these sizes belongs to a *picture* rather than to text: a single letter
    /// filling a generated cover, the glyph standing in for missing artwork, the icons on
    /// the setup and pairing screens. Growing those with the reader's text size would
    /// distort the artwork they are standing in for, not make anything more legible.
    private static let deliberatelyFixed: Set<String> = [
        "GeneratedPlaylistCoverView.swift",
        "AlbumArtworkView.swift",
        "PairingQRCodeView.swift",
        "LibrarySetupView.swift",
        "DevicesView.swift",
        "ContentView.swift",
    ]

    func testNoViewPinsReadableTextToAFixedSize() throws {
        // A *literal* size is the thing that cannot scale. `.system(size: someMetric)` fed
        // by an `@ScaledMetric` already grows correctly and must not be flagged — that is
        // how `AddDeviceSheet` sizes the pairing code, and it was doing this right before
        // anything else was.
        let literalSize = try NSRegularExpression(
            pattern: #"\.system\(size:\s*\d|AroFont\.fixed\(\s*\d"#
        )

        let offenders = try sourceFiles().compactMap { url -> String? in
            guard !Self.deliberatelyFixed.contains(url.lastPathComponent),
                  // The design system names these constructs to define and document them.
                  url.lastPathComponent != "AroTypography.swift" else {
                return nil
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            let pinned = literalSize.firstMatch(in: source, range: range) != nil
            return pinned ? url.lastPathComponent : nil
        }

        XCTAssertEqual(
            offenders.sorted(),
            [],
            """
            These views pin text to a fixed point size, so it will not grow when someone \
            turns up their system text size. Use AroFont.textStyle for a named style, or \
            AroFont.scaled(_:relativeTo:) for a size between two of them. If the size really \
            belongs to a picture rather than to reading, add the file to `deliberatelyFixed` \
            above with the reason.
            """
        )
    }

    /// A size declared relative to the wrong style still scales, but along the wrong axis —
    /// a caption pegged to `.largeTitle` grows far faster than the text around it. Checking
    /// the pairing is what keeps `scaled` honest rather than merely present.
    func testScaledSizesAreAnchoredToTheNearestTextStyle() throws {
        let pattern = try NSRegularExpression(
            pattern: #"AroFont\.scaled\(\s*(\d+)\s*,\s*relativeTo:\s*\.(\w+)"#
        )

        var mismatches: [String] = []
        for url in try sourceFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                guard let sizeRange = Range(match.range(at: 1), in: source),
                      let styleRange = Range(match.range(at: 2), in: source),
                      let size = Double(source[sizeRange]) else {
                    continue
                }
                let declared = String(source[styleRange])
                let expected = Self.name(
                    of: AroFont.nearestStyle(to: CGFloat(size))
                )
                if declared != expected {
                    mismatches.append(
                        "\(url.lastPathComponent): \(Int(size))pt is anchored to "
                            + ".\(declared), nearest is .\(expected)"
                    )
                }
            }
        }

        XCTAssertEqual(mismatches.sorted(), [], mismatches.sorted().joined(separator: "\n"))
    }

    private static func name(of style: Font.TextStyle) -> String {
        switch style {
        case .largeTitle: "largeTitle"
        case .title: "title"
        case .title2: "title2"
        case .title3: "title3"
        case .headline: "headline"
        case .subheadline: "subheadline"
        case .callout: "callout"
        case .caption: "caption"
        case .caption2: "caption2"
        case .footnote: "footnote"
        case .body: "body"
        @unknown default: "body"
        }
    }

    /// Walks up from this file to the package root, so the test does not depend on where
    /// the test bundle happens to be built.
    private func sourceFiles() throws -> [URL] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let sources = root.appendingPathComponent("Sources/Aro")

        var found: [URL] = []
        let walker = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: nil
        )
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension == "swift" { found.append(url) }
        }
        XCTAssertFalse(
            found.isEmpty,
            "found no sources under \(sources.path) — the test is walking the wrong tree"
        )
        return found
    }
}
#endif
