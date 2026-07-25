#if canImport(XCTest)
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Sonora

final class AudioScannerTests: XCTestCase {
    func testRecursivelyFindsAudioAndSkipsHiddenPackagesAndSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        let package = root.appendingPathComponent("Ignored.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )

        try Data(repeating: 1, count: 10).write(
            to: root.appendingPathComponent("Alpha.mp3")
        )
        try Data(repeating: 1, count: 20).write(
            to: nested.appendingPathComponent("Beta.wav")
        )
        try Data().write(to: root.appendingPathComponent(".Hidden.m4a"))
        try Data().write(to: package.appendingPathComponent("Packaged.mp3"))
        try Data().write(to: root.appendingPathComponent("Notes.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Linked.mp3"),
            withDestinationURL: root.appendingPathComponent("Alpha.mp3")
        )

        let scanner = AudioScanner(
            metadataReader: StubMetadataReader(),
            fileRecognizer: StubAudioFileRecognizer()
        )
        let result = await scanner.scan(folder: root)

        XCTAssertEqual(result.songs.map(\.title), ["Alpha", "Beta"])
        XCTAssertEqual(result.songs.map(\.artist), ["Test Artist", "Test Artist"])
        XCTAssertEqual(result.songs.map(\.fileSizeBytes), [10, 20])
        XCTAssertEqual(result.songs.map(\.artworkData), [Data([1, 2]), Data([1, 2])])
        XCTAssertEqual(result.skippedFileCount, 0)
    }

    func testUnreadableMetadataIsSkippedWithoutFailingScan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data().write(to: root.appendingPathComponent("Playable.mp3"))
        try Data().write(to: root.appendingPathComponent("Broken.mp3"))

        let scanner = AudioScanner(
            metadataReader: StubMetadataReader(unreadableFilename: "Broken.mp3"),
            fileRecognizer: StubAudioFileRecognizer()
        )
        let result = await scanner.scan(folder: root)

        XCTAssertEqual(result.songs.map(\.title), ["Playable"])
        XCTAssertEqual(result.skippedFileCount, 1)
    }
}

private struct StubAudioFileRecognizer: AudioFileRecognizing {
    func isAudioFile(at url: URL, resourceType: UTType?) -> Bool {
        ["mp3", "wav", "m4a"].contains(url.pathExtension.lowercased())
    }
}

private struct StubMetadataReader: AudioMetadataReading {
    var unreadableFilename: String?

    func metadata(for url: URL) async -> AudioMetadata? {
        guard url.lastPathComponent != unreadableFilename else {
            return nil
        }

        return AudioMetadata(
            title: nil,
            artist: "Test Artist",
            artworkData: Data([1, 2]),
            duration: 185
        )
    }
}
#endif
