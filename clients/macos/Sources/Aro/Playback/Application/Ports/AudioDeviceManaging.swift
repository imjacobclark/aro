import Foundation
import AroCommon

@MainActor
protocol AudioDeviceManaging: AnyObject {
    var devices: [AudioOutputDevice] { get }
    var lastWarning: String? { get }
    /// The device macOS is sending audio to. Aro follows this rather than keeping a private
    /// route, so it is the one authority on where sound comes out.
    var defaultDevice: AudioOutputDevice? { get }
    /// Invoked when macOS switches output, so playback can re-route mid-track.
    var defaultDeviceDidChange: ((AudioOutputDevice?) -> Void)? { get set }

    func refresh()
    func selectedDevice(for uid: String?) -> AudioOutputDevice?
    func device(withID id: UInt32) -> AudioOutputDevice?
    func nominalSampleRate(for device: AudioOutputDevice) -> Double?
    func configure(
        device: AudioOutputDevice,
        sampleRate: Double,
        acquireHogMode: Bool
    ) throws -> Bool
    func releaseHogMode(for device: AudioOutputDevice?)
    @discardableResult
    func setSystemDefaultOutputDevice(_ device: AudioOutputDevice) -> Bool
}
