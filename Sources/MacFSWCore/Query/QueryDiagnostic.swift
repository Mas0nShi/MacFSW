import Foundation

/// A named healing event from the lenient parser. Parsing NEVER fails —
/// every diagnostic describes how degenerate input was interpreted anyway.
/// The load-bearing invariant, enforced by tests:
/// `parseDetailed(s).query == parse(s)` for every input.
public struct MacFSWQueryDiagnostic: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case unknownField(name: String)
        case emptyValue(fieldText: String)
        case unbalancedOpenParen
        case unexpectedCloseParen
        case unterminatedQuote
        case danglingOperator(keyword: String)
    }

    public let kind: Kind
    /// Span of the offending text in the raw source, when attributable.
    public let range: Range<String.Index>?
    public let message: String

    init(kind: Kind, range: Range<String.Index>?) {
        self.kind = kind
        self.range = range
        self.message = Self.message(for: kind)
    }

    private static func message(for kind: Kind) -> String {
        switch kind {
        case .unknownField(let name):
            return "Unknown field '\(name)' — matched as plain text"
        case .emptyValue(let fieldText):
            return "Field '\(fieldText)' has no value — matched as plain text"
        case .unbalancedOpenParen:
            return "Unclosed '(' — group runs to the end of the query"
        case .unexpectedCloseParen:
            return "Stray ')' — it and any following input are ignored"
        case .unterminatedQuote:
            return "Unclosed quote — it runs to the end of the query"
        case .danglingOperator(let keyword):
            return "'\(keyword)' has no operand — ignored"
        }
    }
}

public struct MacFSWQueryParseResult: Sendable {
    public let query: MacFSWEventQuery
    public let tokens: MacFSWQueryTokenStream
    public let diagnostics: [MacFSWQueryDiagnostic]
}
