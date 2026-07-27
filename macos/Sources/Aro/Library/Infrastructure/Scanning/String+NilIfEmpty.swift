import AroCommon

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
