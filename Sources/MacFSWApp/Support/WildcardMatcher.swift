import Foundation

enum WildcardMatcher {
    static func matches(_ pattern: String, value: String) -> Bool {
        let pattern = Array(pattern.lowercased())
        let value = Array(value.lowercased())
        var patternIndex = 0
        var valueIndex = 0
        var starIndex: Int?
        var starValueIndex = 0

        while valueIndex < value.count {
            if patternIndex < pattern.count,
               (pattern[patternIndex] == "?" || pattern[patternIndex] == value[valueIndex]) {
                patternIndex += 1
                valueIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                starValueIndex = valueIndex
                patternIndex += 1
            } else if let starIndex {
                patternIndex = starIndex + 1
                starValueIndex += 1
                valueIndex = starValueIndex
            } else {
                return false
            }
        }

        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }
}

typealias MacFSWWildcard = WildcardMatcher
