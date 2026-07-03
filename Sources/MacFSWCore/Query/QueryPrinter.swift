import Foundation

/// Canonical expression → query text. The round-trip invariant, enforced by
/// property tests: `parse(canonicalText(for: e)).expression == e` for every
/// parser-representable expression.
///
/// Known representational limits (documented in docs/query-syntax.md):
/// values containing `"` cannot be quoted (quotes never escape); values
/// containing `,` always split; and a `<`/`>` comparison whose first value
/// starts with `=` merges into `<=`/`>=` when printed (quoting cannot help —
/// field splitting runs on quote-stripped token text). Such expressions are
/// not representable as query text.
public enum MacFSWQueryPrinter {
    public static func canonicalText(for expression: MacFSWQueryExpression) -> String {
        text(for: expression)
    }

    private static func text(for expression: MacFSWQueryExpression) -> String {
        switch expression {
        case .predicate(let predicate):
            return text(for: predicate)
        case .not(let operand):
            if case .predicate = operand {
                return "NOT " + text(for: operand)
            }
            return "NOT (" + text(for: operand) + ")"
        case .and(let children):
            return children.map(childText).joined(separator: " ")
        case .or(let children):
            return children.map(childText).joined(separator: " OR ")
        }
    }

    /// Non-predicate children are always parenthesized. This is what lets a
    /// nested same-operator tree (`.or([.or([a, b]), c])`) survive the
    /// parser's chain flattening.
    private static func childText(_ child: MacFSWQueryExpression) -> String {
        if case .predicate = child {
            return text(for: child)
        }
        return "(" + text(for: child) + ")"
    }

    private static func text(for predicate: MacFSWQueryPredicate) -> String {
        if predicate.field == .any,
           predicate.comparison == .contains,
           predicate.values.count == 1,
           isBareSafe(predicate.values[0]) {
            return predicate.values[0]
        }

        let key = MacFSWQueryFieldCatalog.descriptor(for: predicate.field)?.canonicalKey ?? "any"
        let values = predicate.values.map(quotedIfNeeded).joined(separator: ",")
        return key + operatorText(for: predicate.comparison) + values
    }

    private static func operatorText(for comparison: MacFSWQueryComparison) -> String {
        switch comparison {
        case .contains: ":"
        case .equals: "="
        case .notEquals: "!="
        case .greaterThan: ">"
        case .greaterOrEqual: ">="
        case .lessThan: "<"
        case .lessOrEqual: "<="
        }
    }

    private static func quotedIfNeeded(_ value: String) -> String {
        let needsQuoting = value.contains(where: \.isWhitespace)
            || value.contains("(")
            || value.contains(")")
        return needsQuoting ? "\"\(value)\"" : value
    }

    /// A value may print as a bare word only when lexing + splitting will
    /// hand it back verbatim: no whitespace/parens (token boundaries), no
    /// operator characters (field split), no keyword spelling, no leading
    /// "-" (negation sugar), no quote or comma (unrepresentable anyway).
    private static func isBareSafe(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("-") else {
            return false
        }
        let unsafeCharacters: Set<Character> = ["\"", ",", "(", ")", ":", "=", ">", "<"]
        guard !value.contains(where: { $0.isWhitespace || unsafeCharacters.contains($0) }) else {
            return false
        }
        switch value.uppercased() {
        case "AND", "OR", "NOT":
            return false
        default:
            return true
        }
    }
}
