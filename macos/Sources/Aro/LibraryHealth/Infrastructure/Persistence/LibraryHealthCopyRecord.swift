import AroCommon

struct LibraryHealthCopyRecord: Sendable {
    let path: String
    let isAvailable: Bool
    let codec: String?
    let sampleRate: Double?
    let bitDepth: Int?
    let bitrate: Double?
    let fileSizeBytes: Int64
}
