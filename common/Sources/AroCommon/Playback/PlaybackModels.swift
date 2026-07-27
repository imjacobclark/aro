public struct AudioSampleRateRange: Hashable, Sendable {
    public let minimum: Double
    public let maximum: Double

    public init(minimum: Double, maximum: Double) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public func contains(_ sampleRate: Double) -> Bool {
        sampleRate >= minimum - 0.5 && sampleRate <= maximum + 0.5
    }

    public func nearestRate(to sampleRate: Double) -> Double {
        min(max(sampleRate, minimum), maximum)
    }
}

public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public let transport: AudioOutputTransport
    public let id: UInt32
    public let uid: String
    public let name: String
    public let sampleRateRanges: [AudioSampleRateRange]

    public init(
        id: UInt32,
        uid: String,
        name: String,
        sampleRateRanges: [AudioSampleRateRange],
        transport: AudioOutputTransport = .other
    ) {
        self.transport = transport
        self.id = id
        self.uid = uid
        self.name = name
        self.sampleRateRanges = sampleRateRanges
    }

    public func supports(sampleRate: Double) -> Bool {
        sampleRateRanges.contains { $0.contains(sampleRate) }
    }

    public func nearestSupportedSampleRate(to sampleRate: Double) -> Double? {
        sampleRateRanges
            .map { $0.nearestRate(to: sampleRate) }
            .min { abs($0 - sampleRate) < abs($1 - sampleRate) }
    }
}

public enum AudioOutputTransport: String, CaseIterable, Codable, Sendable {
    case builtIn
    case usb
    case bluetooth
    case airPlay
    case other

    public var isWireless: Bool {
        self == .bluetooth || self == .airPlay
    }

    public var displayName: String {
        switch self {
        case .builtIn: return "Built-in"
        case .usb: return "USB"
        case .bluetooth: return "Bluetooth"
        case .airPlay: return "AirPlay"
        case .other: return "Other"
        }
    }

    public var systemImageName: String {
        switch self {
        case .builtIn: return "laptopcomputer"
        case .usb: return "cable.connector"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .airPlay: return "airplayaudio"
        case .other: return "hifispeaker"
        }
    }
}

public enum PlaybackMode: String, CaseIterable, Codable, Sendable {
    case bitPerfect
    case normalized

    public var displayName: String {
        switch self {
        case .bitPerfect:
            return "Bit-Perfect"
        case .normalized:
            return "Normalized"
        }
    }
}

public struct PlaybackOutputStatus: Equatable, Sendable {
    public var mode: PlaybackMode
    public var transport: AudioOutputTransport
    public var deviceName: String
    public var sourceCodec: String?
    public var sourceSampleRate: Double?
    public var sourceBitDepth: Int?
    public var sourceChannelCount: Int?
    public var sampleRate: Double?
    public var bitDepth: Int?
    public var isExclusive: Bool
    public var appliedGainDecibels: Double
    public var warning: String?

    public init(
        mode: PlaybackMode = .bitPerfect,
        transport: AudioOutputTransport = .other,
        deviceName: String = "System Default",
        sourceCodec: String? = nil,
        sourceSampleRate: Double? = nil,
        sourceBitDepth: Int? = nil,
        sourceChannelCount: Int? = nil,
        sampleRate: Double? = nil,
        bitDepth: Int? = nil,
        isExclusive: Bool = false,
        appliedGainDecibels: Double = 0,
        warning: String? = nil
    ) {
        self.mode = mode
        self.transport = transport
        self.deviceName = deviceName
        self.sourceCodec = sourceCodec
        self.sourceSampleRate = sourceSampleRate
        self.sourceBitDepth = sourceBitDepth
        self.sourceChannelCount = sourceChannelCount
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.isExclusive = isExclusive
        self.appliedGainDecibels = appliedGainDecibels
        self.warning = warning
    }
}

public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case playing
    case paused
    case failed(String)
}

public struct VisualizerLevelSmoother {
    public init() {}

    public func update(
        current: [Double],
        incoming: [Double]
    ) -> [Double] {
        guard incoming.count == current.count else {
            return incoming
        }
        guard incoming.contains(where: { $0 > 0 }) else {
            return incoming
        }

        return zip(current, incoming).map { current, incoming in
            let response = incoming > current ? 0.62 : 0.18
            return current + (incoming - current) * response
        }
    }
}
