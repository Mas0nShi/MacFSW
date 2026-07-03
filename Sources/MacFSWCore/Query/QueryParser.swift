import Foundation

public enum MacFSWQueryParser {
    public static func parse(_ rawText: String, base: MacFSWEventQuery = MacFSWEventQuery()) -> MacFSWEventQuery {
        var query = base
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        query.text = trimmed
        query.expression = nil

        guard !trimmed.isEmpty else {
            return query
        }

        var parser = ExpressionParser(tokens: MacFSWQueryLexer.tokenize(rawText).tokens)
        query.expression = parser.parse()
        return query
    }
}

private struct ExpressionParser {
    var tokens: [MacFSWQueryToken]
    var index = 0

    mutating func parse() -> MacFSWQueryExpression? {
        parseOr()
    }

    private mutating func parseOr() -> MacFSWQueryExpression? {
        guard var expression = parseAnd() else {
            return nil
        }

        var expressions = [expression]
        while consume(.or) {
            guard let right = parseAnd() else {
                break
            }
            expressions.append(right)
        }

        if expressions.count > 1 {
            expression = .or(expressions)
        }
        return expression
    }

    private mutating func parseAnd() -> MacFSWQueryExpression? {
        guard let first = parseUnary() else {
            return nil
        }

        var expressions = [first]
        while true {
            if consume(.and) {
                if let next = parseUnary() {
                    expressions.append(next)
                }
                continue
            }

            guard startsPrimary(peek?.kind) else {
                break
            }

            if let next = parseUnary() {
                expressions.append(next)
            } else {
                break
            }
        }

        return expressions.count == 1 ? expressions[0] : .and(expressions)
    }

    private mutating func parseUnary() -> MacFSWQueryExpression? {
        if consume(.not) {
            guard let expression = parseUnary() else {
                return nil
            }
            return .not(expression)
        }
        return parsePrimary()
    }

    private mutating func parsePrimary() -> MacFSWQueryExpression? {
        guard let token = peek else {
            return nil
        }

        switch token.kind {
        case .leftParen:
            advance()
            let expression = parseOr()
            _ = consume(.rightParen)
            return expression
        case .word:
            advance()
            return .predicate(predicate(for: token.text))
        case .and, .or, .not, .rightParen:
            return nil
        }
    }

    private func predicate(for word: String) -> MacFSWQueryPredicate {
        guard let split = MacFSWQueryFieldTerm.split(word),
              !split.fieldText.isBlank,
              !split.valueText.isBlank,
              let field = MacFSWQueryFieldCatalog.field(forRawKey: split.fieldText) else {
            return MacFSWQueryPredicate(field: .any, comparison: .contains, values: [word])
        }

        return MacFSWQueryPredicate(
            field: field,
            comparison: split.comparison,
            values: splitValues(split.valueText)
        )
    }

    private func splitValues(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var peek: MacFSWQueryToken? {
        index < tokens.count ? tokens[index] : nil
    }

    private mutating func advance() {
        index += 1
    }

    private mutating func consume(_ kind: MacFSWQueryToken.Kind) -> Bool {
        guard peek?.kind == kind else {
            return false
        }
        advance()
        return true
    }

    private func startsPrimary(_ kind: MacFSWQueryToken.Kind?) -> Bool {
        switch kind {
        case .word, .leftParen, .not:
            return true
        case .and, .or, .rightParen, nil:
            return false
        }
    }
}
