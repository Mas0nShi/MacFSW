import AppKit
import MacFSWCore

/// Maps the query front-end's positioned tokens and diagnostics to text
/// attributes for the command bar field. Coloring is UX policy and lives in
/// the App layer; all syntax facts come from Core (lexer, field splitter,
/// catalog) — never a second scanner.
///
/// Palette is deliberately restrained and keeps orange for warnings only:
/// field keys and operators use the accent color, keywords are semibold
/// secondary, quoted values secondary, and unknown-field spans get an orange
/// underline matching the diagnostics icon.
@MainActor
enum QueryHighlighter {
    typealias AttributeRun = (range: NSRange, attributes: [NSAttributedString.Key: Any])

    static func attributeRuns(for result: MacFSWQueryParseResult) -> [AttributeRun] {
        let source = result.tokens.source
        var runs: [AttributeRun] = []

        for token in result.tokens.tokens {
            switch token.kind {
            case .and, .or, .not:
                runs.append((NSRange(token.range, in: source), Self.keywordAttributes))
            case .leftParen, .rightParen:
                runs.append((NSRange(token.range, in: source), Self.parenAttributes))
            case .word:
                runs.append(contentsOf: wordRuns(for: token, in: source))
            }
        }

        for diagnostic in result.diagnostics {
            if case .unknownField = diagnostic.kind, let range = diagnostic.range {
                runs.append((NSRange(range, in: source), Self.unknownFieldAttributes))
            }
        }

        return runs
    }

    private static func wordRuns(for token: MacFSWQueryToken, in source: String) -> [AttributeRun] {
        let raw = String(source[token.range])
        guard let split = MacFSWQueryFieldTerm.split(raw),
              !split.fieldText.isEmpty,
              MacFSWQueryFieldCatalog.field(forRawKey: split.fieldText) != nil else {
            // Plain text terms (and quoted forms whose quote characters make
            // the raw prefix unresolvable) render as values.
            return raw.contains("\"")
                ? [(NSRange(token.range, in: source), Self.quotedValueAttributes)]
                : []
        }

        let keyLength = split.fieldText.count + split.operatorText.count
        let keyEnd = source.index(token.range.lowerBound, offsetBy: keyLength)
        var runs: [AttributeRun] = [
            (NSRange(token.range.lowerBound..<keyEnd, in: source), Self.fieldKeyAttributes)
        ]
        if split.valueText.contains("\"") {
            runs.append((NSRange(keyEnd..<token.range.upperBound, in: source), Self.quotedValueAttributes))
        }
        return runs
    }

    private static let fieldKeyAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.controlAccentColor,
    ]

    private static let keywordAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.secondaryLabelColor,
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
    ]

    private static let parenAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    private static let quotedValueAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    private static let unknownFieldAttributes: [NSAttributedString.Key: Any] = [
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .underlineColor: NSColor.systemOrange,
    ]
}
