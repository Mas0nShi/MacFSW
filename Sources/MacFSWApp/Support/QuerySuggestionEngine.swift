import Foundation
import MacFSWCore

struct QuerySuggestion: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case field(MacFSWQueryField)
        case value
        case keyword
        case history
    }

    let kind: Kind
    let label: String
    let detail: String?
    let resultText: String

    var id: String { label + (detail ?? "") }
}

struct QuerySuggestionContext: Sendable {
    var processNames: [(value: String, detail: String?)] = []
    var pids: [(value: String, detail: String?)] = []
    var executables: [(value: String, detail: String?)] = []
    var signingIDs: [(value: String, detail: String?)] = []
    var teamIDs: [(value: String, detail: String?)] = []
    var history: [String] = []
}

enum QuerySuggestionEngine {
    static func suggestions(for text: String, context: QuerySuggestionContext) -> [QuerySuggestion] {
        let token = trailingToken(of: text)
        guard !token.isInsideQuotes else {
            return []
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return emptyInputSuggestions(context: context)
        }

        switch classify(token.body) {
        case .bare(let prefix):
            var ranked = rankedFieldSuggestions(prefix: prefix, prefixText: token.prefixText)
            if !prefix.isEmpty, !token.isNegated {
                ranked += rankedKeywordSuggestions(prefix: prefix, prefixText: token.prefixText)
            }
            return assemble(ranked)
        case .value(let descriptor, let fieldText, let operatorText, let priorValues, let valuePrefix):
            return valueSuggestions(
                descriptor: descriptor,
                fieldText: fieldText,
                operatorText: operatorText,
                priorValues: priorValues,
                valuePrefix: valuePrefix,
                prefixText: token.prefixText,
                context: context
            )
        case .unknownField:
            return []
        }
    }

    static func context(
        from summaries: [MacFSWProcessSummary],
        history: [String] = []
    ) -> QuerySuggestionContext {
        var context = QuerySuggestionContext()
        context.history = history

        var eventCountByName: [String: Int] = [:]
        for summary in summaries where !summary.processName.isEmpty {
            eventCountByName[summary.processName] = max(eventCountByName[summary.processName] ?? 0, summary.eventCount)
        }
        context.processNames = eventCountByName
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (value: $0.key, detail: eventCountDetail($0.value)) }

        let byActivity = summaries.sorted { left, right in
            if (left.lifecycle == .running) != (right.lifecycle == .running) {
                return left.lifecycle == .running
            }
            return left.eventCount > right.eventCount
        }
        context.pids = deduped(byActivity.map { (value: String($0.pid), detail: $0.processName) })
        context.executables = deduped(byActivity.map { (value: $0.executablePath, detail: $0.processName) })
        // MacFSWProcessSummary only carries the display signing summary
        // (signing ID or team ID); both fields fall back to it, which works
        // because signing:/team: use contains matching.
        let signingValues = deduped(byActivity.map { (value: $0.signingSummary, detail: $0.processName) })
        context.signingIDs = signingValues
        context.teamIDs = signingValues
        return context
    }

    static func nextHighlight(current: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else {
            return nil
        }
        guard let current else {
            return delta >= 0 ? 0 : count - 1
        }
        return min(max(current + delta, 0), count - 1)
    }

    /// Tab cycles through the list and wraps at the edges, unlike the
    /// arrow keys which clamp.
    static func cycledHighlight(current: Int?, delta: Int, count: Int) -> Int? {
        guard count > 0 else {
            return nil
        }
        guard let current else {
            return delta >= 0 ? 0 : count - 1
        }
        return (current + delta + count) % count
    }

    // MARK: - Trailing token

    private struct TrailingToken {
        var body: String
        var prefixText: String
        var isNegated: Bool
        var isInsideQuotes: Bool
    }

    private static func trailingToken(of text: String) -> TrailingToken {
        var inQuotes = false
        var tokenStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes, character.isWhitespace || character == "(" || character == ")" {
                tokenStart = text.index(after: index)
            }
            index = text.index(after: index)
        }

        var body = String(text[tokenStart...])
        var prefixText = String(text[..<tokenStart])
        var isNegated = false
        if body.hasPrefix("-") {
            isNegated = true
            body.removeFirst()
            prefixText += "-"
        }
        return TrailingToken(
            body: body,
            prefixText: prefixText,
            isNegated: isNegated,
            isInsideQuotes: inQuotes
        )
    }

    // MARK: - Classification

    private enum Position {
        case bare(prefix: String)
        case value(
            descriptor: MacFSWQueryFieldDescriptor,
            fieldText: String,
            operatorText: String,
            priorValues: String,
            valuePrefix: String
        )
        case unknownField
    }

    /// Mirrors `MacFSWQueryParser.parseFieldExpression`: same operator set,
    /// same scan order, same catalog lookup — with one deliberate difference:
    /// an empty value ("op:") is a value position here, because that is
    /// exactly the moment the user wants candidates.
    private static let operatorTexts = ["!=", ">=", "<=", "=", ":", ">", "<"]

    private static func classify(_ body: String) -> Position {
        for operatorText in operatorTexts {
            guard let range = body.range(of: operatorText) else {
                continue
            }
            let fieldText = String(body[..<range.lowerBound])
            let valueText = String(body[range.upperBound...])
            guard !fieldText.isEmpty else {
                return .bare(prefix: body)
            }
            guard let field = MacFSWQueryFieldCatalog.field(forRawKey: fieldText),
                  let descriptor = MacFSWQueryFieldCatalog.descriptor(for: field) else {
                return .unknownField
            }

            var priorValues = ""
            var valuePrefix = valueText
            if let lastComma = valueText.lastIndex(of: ",") {
                priorValues = String(valueText[...lastComma])
                valuePrefix = String(valueText[valueText.index(after: lastComma)...])
            }
            return .value(
                descriptor: descriptor,
                fieldText: fieldText,
                operatorText: operatorText,
                priorValues: priorValues,
                valuePrefix: valuePrefix
            )
        }
        return .bare(prefix: body)
    }

    // MARK: - Candidates

    private typealias RankedSuggestion = (rank: Int, order: Int, suggestion: QuerySuggestion)

    private static func assemble(_ ranked: [RankedSuggestion]) -> [QuerySuggestion] {
        ranked
            .sorted { $0.rank == $1.rank ? $0.order < $1.order : $0.rank < $1.rank }
            .map(\.suggestion)
    }

    private static func emptyInputSuggestions(context: QuerySuggestionContext) -> [QuerySuggestion] {
        var results = context.history.map { entry in
            QuerySuggestion(kind: .history, label: entry, detail: "Recent query", resultText: entry)
        }
        results += assemble(rankedFieldSuggestions(prefix: "", prefixText: ""))
        return results
    }

    /// Bare-position ranks: canonical prefix (0) > alias prefix (1) >
    /// keyword prefix (2) > alias contains (3).
    private static func rankedFieldSuggestions(prefix: String, prefixText: String) -> [RankedSuggestion] {
        let normalizedPrefix = MacFSWQueryFieldCatalog.normalizeKey(prefix)
        var matches: [RankedSuggestion] = []

        for (order, descriptor) in MacFSWQueryFieldCatalog.descriptors.enumerated() where descriptor.field != .any {
            let rank: Int
            if normalizedPrefix.isEmpty || descriptor.canonicalKey.hasPrefix(normalizedPrefix) {
                rank = 0
            } else if descriptor.aliases.contains(where: { $0.hasPrefix(normalizedPrefix) }) {
                rank = 1
            } else if descriptor.aliases.contains(where: { $0.contains(normalizedPrefix) }) {
                rank = 3
            } else {
                continue
            }
            matches.append((
                rank: rank,
                order: order,
                suggestion: QuerySuggestion(
                    kind: .field(descriptor.field),
                    label: descriptor.canonicalKey + ":",
                    detail: descriptor.summary,
                    resultText: prefixText + descriptor.canonicalKey + ":"
                )
            ))
        }
        return matches
    }

    private static func rankedKeywordSuggestions(prefix: String, prefixText: String) -> [RankedSuggestion] {
        ["AND", "OR", "NOT"]
            .enumerated()
            .filter { $0.element.lowercased().hasPrefix(prefix.lowercased()) }
            .map { order, keyword in
                (
                    rank: 2,
                    order: order,
                    suggestion: QuerySuggestion(
                        kind: .keyword,
                        label: keyword,
                        detail: "Logical operator",
                        resultText: prefixText + keyword + " "
                    )
                )
            }
    }

    private static func valueSuggestions(
        descriptor: MacFSWQueryFieldDescriptor,
        fieldText: String,
        operatorText: String,
        priorValues: String,
        valuePrefix: String,
        prefixText: String,
        context: QuerySuggestionContext
    ) -> [QuerySuggestion] {
        guard !valuePrefix.contains("*"), !valuePrefix.contains("?") else {
            return []
        }

        let candidates: [(value: String, detail: String?)]
        switch descriptor.valueKind {
        case .eventType:
            candidates = MacFSWEventType.allCases.map { (value: $0.rawValue, detail: nil) }
        case .operationClass:
            candidates = MacFSWOperationClass.allCases.map { (value: $0.rawValue, detail: nil) }
        case .boolean:
            candidates = [(value: "true", detail: nil), (value: "false", detail: nil)]
        case .processName:
            candidates = context.processNames
        case .pid:
            candidates = context.pids
        case .executable:
            candidates = context.executables
        case .signingID:
            candidates = context.signingIDs
        case .teamID:
            candidates = context.teamIDs
        case .path, .numeric, .text:
            return []
        }

        var matches: [RankedSuggestion] = []
        for (order, candidate) in candidates.enumerated() {
            guard !candidate.value.contains("\"") else {
                continue
            }
            let rank: Int
            if valuePrefix.isEmpty {
                rank = 0
            } else if candidate.value.range(of: valuePrefix, options: [.caseInsensitive, .anchored]) != nil {
                rank = 0
            } else if candidate.value.range(of: valuePrefix, options: .caseInsensitive) != nil {
                rank = 1
            } else {
                continue
            }
            let insertedValue = candidate.value.contains(where: \.isWhitespace)
                ? "\"\(candidate.value)\""
                : candidate.value
            matches.append((
                rank: rank,
                order: order,
                suggestion: QuerySuggestion(
                    kind: .value,
                    label: candidate.value,
                    detail: candidate.detail ?? descriptor.summary,
                    resultText: prefixText + fieldText + operatorText + priorValues + insertedValue + " "
                )
            ))
        }

        return assemble(matches)
    }

    private static func deduped(
        _ candidates: [(value: String, detail: String?)]
    ) -> [(value: String, detail: String?)] {
        var seen: Set<String> = []
        return candidates.filter { !$0.value.isEmpty && seen.insert($0.value).inserted }
    }

    private static func eventCountDetail(_ count: Int) -> String {
        count == 1 ? "1 event" : "\(count) events"
    }
}
