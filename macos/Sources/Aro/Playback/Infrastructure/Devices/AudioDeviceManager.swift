import CoreAudio
import AroCommon
import Foundation
import Observation

@MainActor
@Observable
final class AudioDeviceManager: AudioDeviceManaging {
    private(set) var devices: [AudioOutputDevice] = []
    private(set) var lastWarning: String?
    @ObservationIgnored private var previousSampleRates: [AudioObjectID: Double] = [:]

    init() {
        refresh()
    }

    func refresh() {
        devices = Self.allOutputDeviceIDs()
            .compactMap(Self.makeDevice)
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    func selectedDevice(for uid: String?) -> AudioOutputDevice? {
        if let uid, let selected = devices.first(where: { $0.uid == uid }) {
            return selected
        }

        let defaultID = Self.defaultOutputDeviceID()
        return devices.first(where: { $0.id == defaultID })
            ?? devices.first
    }

    func device(withID id: AudioObjectID) -> AudioOutputDevice? {
        devices.first(where: { $0.id == id })
    }

    func nominalSampleRate(for device: AudioOutputDevice) -> Double? {
        Self.nominalSampleRate(deviceID: device.id)
    }

    func configure(
        device: AudioOutputDevice,
        sampleRate: Double,
        acquireHogMode: Bool
    ) throws -> Bool {
        lastWarning = nil
        if device.transport.isWireless {
            lastWarning = PlaybackRoutePolicy().warning(for: device)
            return false
        }
        guard device.supports(sampleRate: sampleRate) else {
            throw AudioDeviceError.unsupportedSampleRate(
                sampleRate: sampleRate,
                deviceName: device.name
            )
        }

        let capturedPreviousRate = previousSampleRates[device.id] == nil
        if capturedPreviousRate {
            previousSampleRates[device.id] = Self.nominalSampleRate(
                deviceID: device.id
            )
        }

        var acquiredHogMode = false
        if acquireHogMode {
            do {
                try Self.setHogMode(deviceID: device.id, pid: getpid())
                acquiredHogMode = true
            } catch {
                lastWarning = "Exclusive access to \(device.name) was unavailable. Playing in shared mode."
            }
        }

        do {
            try Self.setNominalSampleRate(
                deviceID: device.id,
                sampleRate: sampleRate
            )
        } catch {
            if acquiredHogMode {
                try? Self.setHogMode(deviceID: device.id, pid: -1)
            }
            if capturedPreviousRate {
                previousSampleRates.removeValue(forKey: device.id)
            }
            throw error
        }

        return acquiredHogMode
    }

    func releaseHogMode(for device: AudioOutputDevice?) {
        guard let device else {
            return
        }
        try? Self.setHogMode(deviceID: device.id, pid: -1)
        if let previousRate = previousSampleRates.removeValue(
            forKey: device.id
        ) {
            try? Self.setNominalSampleRate(
                deviceID: device.id,
                sampleRate: previousRate
            )
        }
    }

    private static func allOutputDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        var ids = Array(
            repeating: AudioObjectID(0),
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else {
            return []
        }
        // AirPlay endpoints can be advertised by macOS without a conventional
        // output stream until they are selected. Keep them in the picker so
        // they remain discoverable like they are in Audio MIDI Setup.
        return ids.filter { hasOutputStreams($0) || transport(deviceID: $0) == .airPlay }
    }

    private static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ) == noErr && size > 0
    }

    private static func makeDevice(
        id: AudioObjectID
    ) -> AudioOutputDevice? {
        guard let uid: String = stringProperty(
            deviceID: id,
            selector: kAudioDevicePropertyDeviceUID
        ), let name: String = stringProperty(
            deviceID: id,
            selector: kAudioObjectPropertyName
        ) else {
            return nil
        }

        return AudioOutputDevice(
            id: id,
            uid: uid,
            name: name,
            sampleRateRanges: sampleRateRanges(deviceID: id),
            transport: transport(deviceID: id)
        )
    }

    private static func transport(deviceID: AudioObjectID) -> AudioOutputTransport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return .other
        }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        default: return .other
        }
    }

    private func installHardwareListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice
        ]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(system, &address, DispatchQueue.main) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
    }

    private static func stringProperty(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else {
            return nil
        }
        return value?.takeUnretainedValue() as String?
    }

    private static func sampleRateRanges(
        deviceID: AudioObjectID
    ) -> [AudioSampleRateRange] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        var ranges = Array(
            repeating: AudioValueRange(),
            count: Int(size) / MemoryLayout<AudioValueRange>.size
        )
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &ranges
        ) == noErr else {
            return []
        }

        return ranges.compactMap { range in
            guard range.mMinimum > 0, range.mMaximum >= range.mMinimum else {
                return nil
            }
            return AudioSampleRateRange(
                minimum: range.mMinimum,
                maximum: range.mMaximum
            )
        }
    }

    private static func defaultOutputDeviceID() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else {
            return 0
        }
        return deviceID
    }

    private static func setNominalSampleRate(
        deviceID: AudioObjectID,
        sampleRate: Double
    ) throws {
        if let currentRate = nominalSampleRate(deviceID: deviceID),
           abs(currentRate - sampleRate) < 0.5 {
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = sampleRate
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Double>.size),
            &value
        )
        guard status == noErr else {
            throw AudioDeviceError.coreAudio(status)
        }
    }

    private static func nominalSampleRate(
        deviceID: AudioObjectID
    ) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private static func setHogMode(
        deviceID: AudioObjectID,
        pid: pid_t
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = pid
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<pid_t>.size),
            &value
        )
        guard status == noErr else {
            throw AudioDeviceError.coreAudio(status)
        }
    }
}

enum AudioDeviceError: LocalizedError {
    case unsupportedSampleRate(sampleRate: Double, deviceName: String)
    case coreAudio(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedSampleRate(let sampleRate, let deviceName):
            let rate = (sampleRate / 1_000).formatted(
                .number.precision(.fractionLength(0...1))
            )
            return "\(deviceName) does not support \(rate) kHz. Choose another output device or use Normalized mode."
        case .coreAudio(let status):
            return "Core Audio could not configure the output device (error \(status))."
        }
    }
}
