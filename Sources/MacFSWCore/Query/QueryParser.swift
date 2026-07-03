import Foundation

public enum MacFSWQueryParser {
    public static func parse(_ rawText: String, base: MacFSWEventQuery = MacFSWEventQuery()) -> MacFSWEventQuery {
        parseDetailed(rawText, base: base).query
    }

    /// Lenient parse with a side channel of healing diagnostics. The query
    /// is byte-identical to `parse(_:base:)` — diagnostics never change the
    /// interpretation, they only name it.
    public static func parseDetailed(_ rawText: String, base: MacFSWEventQuery = MacFSWEventQuery()) -> MacFSWQueryParseResult {
        var query = base
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        query.text = trimmed
        query.expression = nil

        let stream = MacFSWQueryLexer.tokenize(rawText)
        var diagnostics: [MacFSWQueryDiagnostic] = []
        if stream.endsInsideQuotes {
            let range = rawText.lastIndex(of: "\"").map { $0..<rawText.endIndex }
            diagnostics.append(MacFSWQueryDiagnostic(kind: .unterminatedQuote, range: range))
        }

        guard !trimmed.isEmpty else {
            return MacFSWQueryParseResult(query: query, tokens: stream, diagnostics: diagnostics)
        }

        var parser = ExpressionParser(tokens: stream.tokens)
        query.expression = parser.parse()
        diagnostics.append(contentsOf: parser.diagnostics)

        // The grammar stops at a close paren it never opened; everything
        // after it is discarded (legacy healing, kept as-is).
        if parser.index < stream.tokens.count, stream.tokens[parser.index].kind == .rightParen {
            diagnostics.append(MacFSWQueryDiagnostic(
                kind: .unexpectedCloseParen,
                range: stream.tokens[parser.index].range
            ))
        }

        return MacFSWQueryParseResult(query: query, tokens: stream, diagnostics: diagnostics)
    }
}

private struct ExpressionParser {
    var tokens: [MacFSWQueryToken]
    var index = 0
    var diagnostics: [MacFSWQueryDiagnostic] = []

    mutating func parse() -> MacFSWQueryExpression? {
        parseOr()
    }

    private mutating func parseOr() -> MacFSWQueryExpression? {
        guard var expression = parseAnd() else {
            return nil
        }

        var expressions = [expression]
        while let orToken = consumeToken(.or) {
            guard let right = parseAnd() else {
                reportDangling(orToken)
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
            if let andToken = consumeToken(.and) {
                if let next = parseUnary() {
                    expressions.append(next)
                } else {
                    reportDangling(andToken)
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
        if let notToken = consumeToken(.not) {
            guard let expression = parseUnary() else {
                reportDangling(notToken)
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
            if consumeToken(.rightParen) == nil {
                diagnostics.append(MacFSWQueryDiagnostic(kind: .unbalancedOpenParen, range: token.range))
            }
            return expression
        case .word:
            advance()
            return .predicate(predicate(for: token))
        case .and, .or, .not, .rightParen:
            return nil
        }
    }

    private mutating func predicate(for token: MacFSWQueryToken) -> MacFSWQueryPredicate {
        let word = token.text
        guard let split = MacFSWQueryFieldTerm.split(word), !split.fieldText.isBlank else {
            return MacFSWQueryPredicate(field: .any, comparison: .contains, values: [word])
        }

        guard let field = MacFSWQueryFieldCatalog.field(forRawKey: split.fieldText) else {
            diagnostics.append(MacFSWQueryDiagnostic(
                kind: .unknownField(name: split.fieldText),
                range: token.range
            ))
            return MacFSWQueryPredicate(field: .any, comparison: .contains, values: [word])
        }

        guard !split.valueText.isBlank else {
            diagnostics.append(MacFSWQueryDiagnostic(
                kind: .emptyValue(fieldText: split.fieldText),
                range: token.range
            ))
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

    private mutating func reportDangling(_ token: MacFSWQueryToken) {
        diagnostics.append(MacFSWQueryDiagnostic(
            kind: .danglingOperator(keyword: token.text.uppercased()),
            range: token.range
        ))
    }

    private var peek: MacFSWQueryToken? {
        index < tokens.count ? tokens[index] : nil
    }

    private mutating func advance() {
        index += 1
    }

    private mutating func consumeToken(_ kind: MacFSWQueryToken.Kind) -> MacFSWQueryToken? {
        guard let token = peek, token.kind == kind else {
            return nil
        }
        advance()
        return token
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
