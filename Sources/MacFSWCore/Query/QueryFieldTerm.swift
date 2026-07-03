import Foundation

/// The single owner of field/operator/value splitting. The parser and the
/// cursor-context API (completion) both consume this — operator knowledge
/// must never exist in a second place.
enum MacFSWQueryFieldTerm {
    struct Split: Equatable {
        var fieldText: String
        var operatorText: String
        var comparison: MacFSWQueryComparison
        var valueText: String
    }

    private static let twoCharacterOperators: [(String, MacFSWQueryComparison)] = [
        ("!=", .notEquals),
        (">=", .greaterOrEqual),
        ("<=", .lessOrEqual),
    ]

    private static let oneCharacterOperators: [(Character, MacFSWQueryComparison)] = [
        ("=", .equals),
        (":", .contains),
        (">", .greaterThan),
        ("<", .lessThan),
    ]

    /// Leftmost occurrence wins; at a given position the longest operator
    /// wins ("!=" beats "=", ">=" beats ">"). This is what makes
    /// `path:/foo=bar` split at ":" instead of degrading to full text.
    static func split(_ word: String) -> Split? {
        var index = word.startIndex
        while index < word.endIndex {
            for (operatorText, comparison) in twoCharacterOperators {
                if word[index...].hasPrefix(operatorText) {
                    let operatorEnd = word.index(index, offsetBy: operatorText.count)
                    return Split(
                        fieldText: String(word[..<index]),
                        operatorText: operatorText,
                        comparison: comparison,
                        valueText: String(word[operatorEnd...])
                    )
                }
            }
            for (operatorCharacter, comparison) in oneCharacterOperators where word[index] == operatorCharacter {
                return Split(
                    fieldText: String(word[..<index]),
                    operatorText: String(operatorCharacter),
                    comparison: comparison,
                    valueText: String(word[word.index(after: index)...])
                )
            }
            index = word.index(after: index)
        }
        return nil
    }
}
