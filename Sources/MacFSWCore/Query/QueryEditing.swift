import Foundation

/// Programmatic edits to query text that keep the result readable and
/// parseable: the query is treated as its top-level AND terms, terms are
/// removed or added, and the result is printed canonically.
public enum MacFSWQueryEditor {
    /// A field term ready to insert, or nil when `value` cannot be written
    /// as query text (it contains `"` or `,`; see the printer's limits).
    public static func term(
        _ field: MacFSWQueryField,
        _ value: String,
        comparison: MacFSWQueryComparison = .contains,
        negated: Bool = false
    ) -> MacFSWQueryExpression? {
        guard !value.isEmpty, !value.contains("\""), !value.contains(",") else {
            return nil
        }
        let predicate = MacFSWQueryExpression.predicate(MacFSWQueryPredicate(field: field, comparison: comparison, values: [value]))
        return negated ? .not(predicate) : predicate
    }

    /// `text` with every top-level term matching `remove` dropped and
    /// `adding` appended. Terms nested under OR or parentheses are left
    /// alone, since dropping them would change what the rest means.
    public static func editing(
        _ text: String,
        removing remove: (MacFSWQueryExpression) -> Bool = { _ in false },
        adding: [MacFSWQueryExpression] = []
    ) -> String {
        var terms = conjuncts(of: MacFSWQueryParser.parse(text).expression).filter { !remove($0) }
        terms += adding.filter { !terms.contains($0) }
        switch terms.count {
        case 0:
            return ""
        case 1:
            return MacFSWQueryPrinter.canonicalText(for: terms[0])
        default:
            return MacFSWQueryPrinter.canonicalText(for: .and(terms))
        }
    }

    /// The PID a query pins with a top-level `pid:` term, if exactly one.
    public static func pinnedPID(in text: String) -> Int32? {
        let pids = conjuncts(of: MacFSWQueryParser.parse(text).expression).compactMap(pid(of:))
        return pids.count == 1 ? pids[0] : nil
    }

    /// Whether `expression` is a positive `pid:` term.
    public static func isPIDTerm(_ expression: MacFSWQueryExpression) -> Bool {
        pid(of: expression) != nil
    }

    private static func pid(of expression: MacFSWQueryExpression) -> Int32? {
        guard case .predicate(let predicate) = expression,
              predicate.field == .pid,
              predicate.comparison == .contains || predicate.comparison == .equals,
              predicate.values.count == 1 else {
            return nil
        }
        return Int32(predicate.values[0])
    }

    private static func conjuncts(of expression: MacFSWQueryExpression?) -> [MacFSWQueryExpression] {
        switch expression {
        case .none:
            []
        case .and(let terms):
            terms
        case .some(let single):
            [single]
        }
    }
}
