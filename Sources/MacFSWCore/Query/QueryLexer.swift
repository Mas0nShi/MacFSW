import Foundation

public struct MacFSWQueryToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case word
        case leftParen
        case rightParen
        case and
        case or
        case not
    }

    public let kind: Kind
    /// Token payload with quote characters removed (for `.word`).
    public let text: String
    /// Span in `MacFSWQueryTokenStream.source`, including any quote characters.
    public let range: Range<String.Index>

    public init(kind: Kind, text: String, range: Range<String.Index>) {
        self.kind = kind
        self.text = text
        self.range = range
    }
}

/// Tokens are only vended together with the exact string they index, so a
/// range can never be applied to the wrong source by construction.
public struct MacFSWQueryTokenStream: Equatable, Sendable {
    public let source: String
    public let tokens: [MacFSWQueryToken]
    /// True when the input ends with an unterminated quote.
    public let endsInsideQuotes: Bool
}

/// The single lexer for the query language. The parser, the cursor-context
/// API (completion), and syntax highlighting all consume this tokenization —
/// there is deliberately no second implementation of these rules anywhere.
///
/// Lexical contract (frozen by QueryGoldenCorpusTests):
/// - Tokens split on unquoted whitespace; `(` `)` are structural outside quotes.
/// - `"` toggles verbatim mode and is stripped from the token text. Quoting
///   protects whitespace and parens — NOT keywords, operators, or commas.
/// - AND/OR/NOT classify case-insensitively AFTER quote stripping.
/// - A leading `-` on a token longer than one character is NOT sugar; the
///   remainder is always a word and is never re-classified as a keyword.
public enum MacFSWQueryLexer {
    public static func tokenize(_ input: String) -> MacFSWQueryTokenStream {
        var tokens: [MacFSWQueryToken] = []
        var currentText = ""
        var currentStart: String.Index?
        var inQuotes = false

        func flushCurrent(endingAt end: String.Index) {
            defer {
                currentText.removeAll(keepingCapacity: true)
                currentStart = nil
            }
            guard let start = currentStart, !currentText.isEmpty else {
                return
            }
            appendClassified(text: currentText, range: start..<end, source: input, into: &tokens)
        }

        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            let next = input.index(after: index)

            if character == "\"" {
                if currentStart == nil {
                    currentStart = index
                }
                inQuotes.toggle()
            } else if !inQuotes, character == "(" {
                flushCurrent(endingAt: index)
                tokens.append(MacFSWQueryToken(kind: .leftParen, text: "(", range: index..<next))
            } else if !inQuotes, character == ")" {
                flushCurrent(endingAt: index)
                tokens.append(MacFSWQueryToken(kind: .rightParen, text: ")", range: index..<next))
            } else if !inQuotes, character.isWhitespace {
                flushCurrent(endingAt: index)
            } else {
                if currentStart == nil {
                    currentStart = index
                }
                currentText.append(character)
            }
            index = next
        }
        flushCurrent(endingAt: input.endIndex)

        return MacFSWQueryTokenStream(source: input, tokens: tokens, endsInsideQuotes: inQuotes)
    }

    private static func appendClassified(
        text: String,
        range: Range<String.Index>,
        source: String,
        into tokens: inout [MacFSWQueryToken]
    ) {
        switch text.uppercased() {
        case "AND":
            tokens.append(MacFSWQueryToken(kind: .and, text: text, range: range))
        case "OR":
            tokens.append(MacFSWQueryToken(kind: .or, text: text, range: range))
        case "NOT":
            tokens.append(MacFSWQueryToken(kind: .not, text: text, range: range))
        default:
            if text.hasPrefix("-"), text.count > 1 {
                let remainder = String(text.dropFirst())
                if source[range.lowerBound] == "-" {
                    let dashEnd = source.index(after: range.lowerBound)
                    tokens.append(MacFSWQueryToken(kind: .not, text: "-", range: range.lowerBound..<dashEnd))
                    tokens.append(MacFSWQueryToken(kind: .word, text: remainder, range: dashEnd..<range.upperBound))
                } else {
                    // The "-" is hidden behind a quote (e.g. "\"-x\""); the
                    // exact split is not representable, so both tokens share
                    // the raw span.
                    tokens.append(MacFSWQueryToken(kind: .not, text: "-", range: range))
                    tokens.append(MacFSWQueryToken(kind: .word, text: remainder, range: range))
                }
            } else {
                tokens.append(MacFSWQueryToken(kind: .word, text: text, range: range))
            }
        }
    }
}
