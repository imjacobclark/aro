import Foundation

public enum FuzzySearch {
    public static func matches(_ query: String, in candidate: String) -> Bool {
        let tokens = normalized(query)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return true }

        let candidate = normalized(candidate)
        return tokens.allSatisfy { token in
            candidate.contains(token) || isSubsequence(token, of: candidate)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    private static func isSubsequence(
        _ needle: String,
        of haystack: String
    ) -> Bool {
        var remaining = needle[...]
        for character in haystack {
            guard remaining.first == character else { continue }
            remaining.removeFirst()
            if remaining.isEmpty {
                return true
            }
        }
        return remaining.isEmpty
    }
}
