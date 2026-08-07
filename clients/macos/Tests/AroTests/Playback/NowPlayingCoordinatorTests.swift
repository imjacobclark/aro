#if canImport(XCTest)
import Foundation
import AroCommon
import MediaPlayer
import XCTest
@testable import Aro

final class NowPlayingCoordinatorTests: XCTestCase {
    func testNowPlayingInfoIsNilWithoutASong() {
        XCTAssertNil(
            MPNowPlayingPublisher.nowPlayingInfo(
                song: nil,
                elapsedTime: 0,
                duration: 0,
                isPlaying: false
            )
        )
    }

    func testNowPlayingInfoReflectsCurrentSongAndPlaybackState() throws {
        let song = Song(
            url: URL(fileURLWithPath: "/Music/Alpha.flac"),
            title: "Alpha",
            artist: "Artist",
            duration: 180
        )

        let playingInfo = try XCTUnwrap(
            MPNowPlayingPublisher.nowPlayingInfo(
                song: song,
                elapsedTime: 42,
                duration: 180,
                isPlaying: true
            )
        )
        XCTAssertEqual(playingInfo[MPMediaItemPropertyTitle] as? String, "Alpha")
        XCTAssertEqual(playingInfo[MPMediaItemPropertyArtist] as? String, "Artist")
        XCTAssertEqual(
            playingInfo[MPMediaItemPropertyPlaybackDuration] as? TimeInterval,
            180
        )
        XCTAssertEqual(
            playingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval,
            42
        )
        XCTAssertEqual(
            playingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double,
            1.0
        )

        let pausedInfo = try XCTUnwrap(
            MPNowPlayingPublisher.nowPlayingInfo(
                song: song,
                elapsedTime: 42,
                duration: 180,
                isPlaying: false
            )
        )
        XCTAssertEqual(
            pausedInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double,
            0.0
        )
    }
}
#endif
