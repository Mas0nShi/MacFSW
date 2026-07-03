import Foundation

/// Where the user's caret is, syntactically, when typing at the END of a
/// query — the input completion tooling needs. Derived from the one lexer
/// (`MacFSWQueryLexer`) and the one field splitter (`MacFSWQueryFieldTerm`);
/// there is deliberately no second scanner that could drift from the parser.
public struct MacFSWQueryCursorContext: Equatable, Sendable {
    public enum Position: Equatable, Sendable {
        case insideQuotes
        case bare(prefix: String)
        case fieldValue(
            descriptor: MacFSWQueryFieldDescriptor,
            fieldText: String,
            operatorText: String,
            priorValues: String,
            valuePrefix: String
        )
        case unknownField(fieldText: String)
    }

    public let position: Position
    /// Everything before the trailing token, with a folded negation dash
    /// included — completion builds replacement text as `prefixText` + token.
    public let prefixText: String
    public let isNegated: Bool

    public static func trailing(of text: String) -> MacFSWQueryCursorContext {
        let stream = MacFSWQueryLexer.tokenize(text)
        if stream.endsInsideQuotes {
            return MacFSWQueryCursorContext(position: .insideQuotes, prefixText: text, isNegated: false)
        }

        guard let start = trailingTokenStart(in: stream), start < text.endIndex else {
            // Ends at a token boundary (whitespace/paren) or is empty:
            // a bare position with an empty prefix.
            return MacFSWQueryCursorContext(position: .bare(prefix: ""), prefixText: text, isNegated: false)
        }

        var body = String(text[start...])
        var prefixText = String(text[..<start])
        var isNegated = false
        if body.hasPrefix("-") {
            isNegated = true
            body.removeFirst()
            prefixText += "-"
        }

        return MacFSWQueryCursorContext(
            position: classify(body),
            prefixText: prefixText,
            isNegated: isNegated
        )
    }

    /// The trailing token's start in the raw text: the maximal run of tokens
    /// whose raw spans are contiguous with the end of the input. A dash-sugar
    /// pair (`-x` → NOT + word) shares one raw span and folds back into a
    /// single trailing token; parens are boundaries, never part of the run.
    private static func trailingTokenStart(in stream: MacFSWQueryTokenStream) -> String.Index? {
        var start: String.Index?
        var expectedEnd = stream.source.endIndex
        for token in stream.tokens.reversed() {
            guard token.kind != .leftParen, token.kind != .rightParen,
                  token.range.upperBound == expectedEnd else {
                break
            }
            start = token.range.lowerBound
            expectedEnd = token.range.lowerBound
        }
        return start
    }

    /// One deliberate, documented divergence from the parser: an operator
    /// with an EMPTY value ("op:") is a field-value position here — that is
    /// exactly the moment the user wants value candidates — while the parser
    /// heals the same word to a full-text term.
    private static func classify(_ body: String) -> Position {
        guard let split = MacFSWQueryFieldTerm.split(body), !split.fieldText.isEmpty else {
            return .bare(prefix: body)
        }
        guard let field = MacFSWQueryFieldCatalog.field(forRawKey: split.fieldText),
              let descriptor = MacFSWQueryFieldCatalog.descriptor(for: field) else {
            return .unknownField(fieldText: split.fieldText)
        }

        var priorValues = ""
        var valuePrefix = split.valueText
        if let lastComma = split.valueText.lastIndex(of: ",") {
            priorValues = String(split.valueText[...lastComma])
            valuePrefix = String(split.valueText[split.valueText.index(after: lastComma)...])
        }
        return .fieldValue(
            descriptor: descriptor,
            fieldText: split.fieldText,
            operatorText: split.operatorText,
            priorValues: priorValues,
            valuePrefix: valuePrefix
        )
    }
}
