import AppKit
import MacFSWCore

extension NSAttributedString.Key {
    /// Marks a recognized field term for soft-capsule background drawing by
    /// `QueryTokenLayoutManager`. Value is the capsule's NSColor.
    static let queryTokenBackground = NSAttributedString.Key("MacFSWQueryTokenBackground")
}

/// Maps the query front-end's positioned tokens to text attributes for the
/// command bar field, GitHub-filter-bar style: a recognized field term
/// (`op:rename`) stays plain editable text but carries a soft rounded
/// capsule background for the whole term — key and operator recede to the
/// secondary color, the value keeps the primary color, so words are never
/// split by color alone. Unknown field terms get an orange-tinted capsule
/// (the inline form of the diagnostics warning). Coloring is UX policy and
/// lives in the App layer; all syntax facts come from Core (lexer, field
/// splitter, catalog) — never a second scanner.
@MainActor
enum QueryHighlighter {
    typealias AttributeRun = (range: NSRange, attributes: [NSAttributedString.Key: Any])

    static let tokenBackground = NSColor.labelColor.withAlphaComponent(0.07)
    static let unknownTokenBackground = NSColor.systemOrange.withAlphaComponent(0.16)

    static func attributeRuns(for result: MacFSWQueryParseResult) -> [AttributeRun] {
        let source = result.tokens.source
        var runs: [AttributeRun] = []

        for token in result.tokens.tokens {
            switch token.kind {
            case .and, .or, .not:
                runs.append((NSRange(token.range, in: source), Self.structuralAttributes))
            case .leftParen, .rightParen:
                runs.append((NSRange(token.range, in: source), Self.structuralAttributes))
            case .word:
                runs.append(contentsOf: wordRuns(for: token, in: source))
            }
        }

        return runs
    }

    private static func wordRuns(for token: MacFSWQueryToken, in source: String) -> [AttributeRun] {
        let raw = String(source[token.range])
        guard let split = MacFSWQueryFieldTerm.split(raw), !split.fieldText.isEmpty else {
            return [] // plain full-text terms carry no decoration
        }

        let resolved = MacFSWQueryFieldCatalog.field(forRawKey: split.fieldText) != nil
        let capsule: [NSAttributedString.Key: Any] = [
            .queryTokenBackground: resolved ? Self.tokenBackground : Self.unknownTokenBackground,
        ]

        let keyLength = split.fieldText.count + split.operatorText.count
        let keyEnd = source.index(token.range.lowerBound, offsetBy: keyLength)
        return [
            (NSRange(token.range, in: source), capsule),
            (NSRange(token.range.lowerBound..<keyEnd, in: source), Self.fieldKeyAttributes),
        ]
    }

    private static let fieldKeyAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    private static let structuralAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
}

/// TextKit 1 layout manager that draws `queryTokenBackground` spans as
/// rounded capsules beneath the glyphs, before the default background pass
/// (so the selection highlight still paints on top).
final class QueryTokenLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let textStorage {
            let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            textStorage.enumerateAttribute(.queryTokenBackground, in: characterRange) { value, range, _ in
                guard let color = value as? NSColor else {
                    return
                }
                let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                guard glyphRange.length > 0,
                      let container = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil) else {
                    return
                }
                let rect = boundingRect(forGlyphRange: glyphRange, in: container)
                    .offsetBy(dx: origin.x, dy: origin.y)
                    .insetBy(dx: -2.5, dy: 0.5)
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}
