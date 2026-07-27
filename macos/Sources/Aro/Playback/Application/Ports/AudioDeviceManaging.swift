import Foundation
import AroCommon

@MainActor
protocol AudioDeviceManaging: AnyObject {
    var devices: [AudioOutputDevice] { get }
    var lastWarning: String? { get }

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
}
