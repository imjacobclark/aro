import CoreAudio
import AppKit
import Foundation
import Observation
import SwiftUI

enum PlaybackMode: String, CaseIterable, Codable, Sendable {
    case bitPerfect
    case normalized

    var displayName: String {
        switch self {
        case .bitPerfect:
            return "Bit-Perfect"
        case .normalized:
            return "Normalized"
        }
    }
}

@MainActor
@Observable
final class PlaybackPreferences {
    private enum Key {
        static let mode = "playback.mode"
        static let outputDeviceUID = "playback.outputDeviceUID"
        static let hogMode = "playback.hogMode"
        static let targetLUFS = "playback.targetLUFS"
    }

    var mode: PlaybackMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }

    var outputDeviceUID: String? {
        didSet { defaults.set(outputDeviceUID, forKey: Key.outputDeviceUID) }
    }

    var hogModeEnabled: Bool {
        didSet { defaults.set(hogModeEnabled, forKey: Key.hogMode) }
    }

    var targetLUFS: Double {
        didSet {
            defaults.set(targetLUFS, forKey: Key.targetLUFS)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Key.mode)
            .flatMap(PlaybackMode.init(rawValue:))
            ?? .bitPerfect
        outputDeviceUID = defaults.string(forKey: Key.outputDeviceUID)
        hogModeEnabled = defaults.bool(forKey: Key.hogMode)
        targetLUFS = defaults.object(forKey: Key.targetLUFS) == nil
            ? -14
            : min(max(defaults.double(forKey: Key.targetLUFS), -24), -8)
    }
}

struct AudioSampleRateRange: Hashable, Sendable {
    let minimum: Double
    let maximum: Double

    func contains(_ sampleRate: Double) -> Bool {
        sampleRate >= minimum - 0.5 && sampleRate <= maximum + 0.5
    }

    func nearestRate(to sampleRate: Double) -> Double {
        min(max(sampleRate, minimum), maximum)
    }
}

struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let sampleRateRanges: [AudioSampleRateRange]

    func supports(sampleRate: Double) -> Bool {
        sampleRateRanges.contains { $0.contains(sampleRate) }
    }

    func nearestSupportedSampleRate(to sampleRate: Double) -> Double? {
        sampleRateRanges
            .map { $0.nearestRate(to: sampleRate) }
            .min { abs($0 - sampleRate) < abs($1 - sampleRate) }
    }
}

@MainActor
@Observable
final class AudioDeviceManager {
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
        return ids.filter(hasOutputStreams)
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
            sampleRateRanges: sampleRateRanges(deviceID: id)
        )
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

struct PlaybackSettingsView: View {
    @Bindable var preferences: PlaybackPreferences
    @Bindable var deviceManager: AudioDeviceManager
    let playback: PlaybackController
    @State private var databaseError: String?

    var body: some View {
        Form {
            Picker("Playback Mode", selection: $preferences.mode) {
                ForEach(PlaybackMode.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }

            Picker(
                "Output Device",
                selection: Binding(
                    get: { preferences.outputDeviceUID ?? "" },
                    set: { preferences.outputDeviceUID = $0.isEmpty ? nil : $0 }
                )
            ) {
                Text("System Default").tag("")
                ForEach(deviceManager.devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }

            Toggle("Exclusive Access", isOn: $preferences.hogModeEnabled)
                .help(
                    "Temporarily gives Sonora sole access to the selected output device."
                )

            LabeledContent("Loudness Target") {
                HStack {
                    Slider(value: $preferences.targetLUFS, in: -24 ... -8, step: 1)
                        .frame(width: 180)
                    Text("\(Int(preferences.targetLUFS)) LUFS")
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                }
            }
            .disabled(preferences.mode != .normalized)

            Text(
                preferences.mode == .bitPerfect
                    ? "Bit-Perfect mode uses native sample rates, unity gain, and no audio processing."
                    : "Normalized mode applies constant gain with a −1 dB peak ceiling."
            )
            .font(SonoraFont.footnote)
            .foregroundStyle(.secondary)

            Divider()

            LabeledContent("Library Database") {
                Text(LibraryDatabase.shared.url.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .help(LibraryDatabase.shared.url.path)
            }

            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        LibraryDatabase.shared.url
                    ])
                }
                Button("Export Library…") {
                    exportLibrary()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 380)
        .onAppear {
            deviceManager.refresh()
        }
        .onChange(of: preferences.mode) {
            playback.restartForPlaybackSettingsChange()
        }
        .onChange(of: preferences.outputDeviceUID) {
            playback.restartForPlaybackSettingsChange()
        }
        .onChange(of: preferences.hogModeEnabled) {
            playback.restartForPlaybackSettingsChange()
        }
        .onChange(of: preferences.targetLUFS) {
            playback.refreshNormalizedGain()
        }
        .alert(
            "Unable to Export Library",
            isPresented: Binding(
                get: { databaseError != nil },
                set: { if !$0 { databaseError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(databaseError ?? "Unknown database error.")
        }
    }

    private func exportLibrary() {
        let panel = NSSavePanel()
        panel.title = "Export Sonora Library"
        panel.nameFieldStringValue = "Sonora Library.sqlite3"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }

        do {
            try LibraryDatabase.shared.exportCopy(to: destination)
        } catch {
            databaseError = error.localizedDescription
        }
    }
}
