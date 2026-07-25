import SonoraCommon

struct LibraryHealthTrackRecord: Sendable {
    let id: String
    let contentHash: String?
    let title: String?
    let artist: String?
    let duration: Double?
    var copies: [LibraryHealthCopyRecord]
}
