import Foundation

public struct MacFSWEventQuery: Codable, Equatable, Sendable {
    public var text: String
    public var processIdentity: MacFSWProcessFilterIdentity?
    public var processText: String?
    public var pids: [Int32]
    public var executableText: String?
    public var eventTypes: [MacFSWEventType]
    public var operationClasses: [MacFSWOperationClass]
    public var pathText: String?
    public var signingText: String?
    public var teamText: String?
    public var excludedTeamTexts: [String]
    public var appleControlled: Bool?
    public var platformBinary: Bool?
    public var startTimeNS: UInt64?
    public var endTimeNS: UInt64?
    public var mutationOnly: Bool
    public var limit: Int
    public var excludedTerms: [String]
    public var expression: MacFSWQueryExpression?

    public init(
        text: String = "",
        processIdentity: MacFSWProcessFilterIdentity? = nil,
        processText: String? = nil,
        pids: [Int32] = [],
        executableText: String? = nil,
        eventTypes: [MacFSWEventType] = [],
        operationClasses: [MacFSWOperationClass] = [],
        pathText: String? = nil,
        signingText: String? = nil,
        teamText: String? = nil,
        excludedTeamTexts: [String] = [],
        appleControlled: Bool? = nil,
        platformBinary: Bool? = nil,
        startTimeNS: UInt64? = nil,
        endTimeNS: UInt64? = nil,
        mutationOnly: Bool = false,
        limit: Int = 0,
        excludedTerms: [String] = [],
        expression: MacFSWQueryExpression? = nil
    ) {
        self.text = text
        self.processIdentity = processIdentity
        self.processText = processText
        self.pids = pids
        self.executableText = executableText
        self.eventTypes = eventTypes
        self.operationClasses = operationClasses
        self.pathText = pathText
        self.signingText = signingText
        self.teamText = teamText
        self.excludedTeamTexts = excludedTeamTexts
        self.appleControlled = appleControlled
        self.platformBinary = platformBinary
        self.startTimeNS = startTimeNS
        self.endTimeNS = endTimeNS
        self.mutationOnly = mutationOnly
        self.limit = limit
        self.excludedTerms = excludedTerms
        self.expression = expression
    }

    public var hasVisibleLimit: Bool {
        limit > 0
    }

    public func visibleCount(totalCount: Int) -> Int {
        let totalCount = max(0, totalCount)
        guard hasVisibleLimit else {
            return totalCount
        }
        return min(totalCount, limit)
    }

    public func matches(_ event: MacFSWFileEvent) -> Bool {
        guard matchesLegacyFilters(event, includeText: expression == nil) else {
            return false
        }
        if let expression {
            return expression.matches(event)
        }
        return true
    }

    private func matchesLegacyFilters(_ event: MacFSWFileEvent, includeText: Bool) -> Bool {
        if let startTimeNS, event.timestampNS < startTimeNS {
            return false
        }
        if let endTimeNS, event.timestampNS > endTimeNS {
            return false
        }
        if mutationOnly, !event.eventType.isMutation {
            return false
        }
        if !pids.isEmpty, !pids.contains(event.process.pid) {
            return false
        }
        if let processIdentity, !processIdentity.matches(event.process) {
            return false
        }
        if !eventTypes.isEmpty, !eventTypes.contains(event.eventType) {
            return false
        }
        if !operationClasses.isEmpty, !operationClasses.contains(event.operationClass) {
            return false
        }
        if let processText, !processText.isBlank,
           !MacFSWQueryMatcher.matches(processText, in: event.queryValues(for: .processName) + event.queryValues(for: .executable)) {
            return false
        }
        if let executableText, !executableText.isBlank,
           !MacFSWQueryMatcher.matches(executableText, in: event.queryValues(for: .executable)) {
            return false
        }
        if let pathText, !pathText.isBlank,
           !MacFSWQueryMatcher.matches(pathText, in: event.queryValues(for: .path)) {
            return false
        }
        if let signingText, !signingText.isBlank,
           !MacFSWQueryMatcher.matches(signingText, in: event.queryValues(for: .signingID)) {
            return false
        }
        if excludedTeamTexts.contains(where: { MacFSWQueryMatcher.matches($0, in: event.queryValues(for: .teamID)) }) {
            return false
        }
        if let teamText, !teamText.isBlank,
           !MacFSWQueryMatcher.matches(teamText, in: event.queryValues(for: .teamID)) {
            return false
        }
        if let appleControlled, event.process.isAppleControlled != appleControlled {
            return false
        }
        if let platformBinary, event.process.isPlatformBinary != platformBinary {
            return false
        }
        for term in excludedTerms where !term.isBlank {
            if MacFSWQueryMatcher.matches(term, in: event.fullTextValues) {
                return false
            }
        }
        if includeText, !text.isBlank, !MacFSWQueryMatcher.matches(text, in: event.fullTextValues) {
            return false
        }
        return true
    }
}

public indirect enum MacFSWQueryExpression: Codable, Equatable, Sendable {
    case predicate(MacFSWQueryPredicate)
    case not(MacFSWQueryExpression)
    case and([MacFSWQueryExpression])
    case or([MacFSWQueryExpression])

    public func matches(_ event: MacFSWFileEvent) -> Bool {
        switch self {
        case .predicate(let predicate):
            return predicate.matches(event)
        case .not(let expression):
            return !expression.matches(event)
        case .and(let expressions):
            return expressions.allSatisfy { $0.matches(event) }
        case .or(let expressions):
            return expressions.contains { $0.matches(event) }
        }
    }
}

public struct MacFSWQueryPredicate: Codable, Equatable, Sendable {
    public var field: MacFSWQueryField
    public var comparison: MacFSWQueryComparison
    public var values: [String]

    public init(field: MacFSWQueryField = .any, comparison: MacFSWQueryComparison = .contains, values: [String]) {
        self.field = field
        self.comparison = comparison
        self.values = values
    }

    public func matches(_ event: MacFSWFileEvent) -> Bool {
        let values = values.filter { !$0.isBlank }
        guard !values.isEmpty else {
            return true
        }

        switch comparison {
        case .contains, .equals:
            return values.contains { valueMatches($0, event: event, equalityOnly: comparison == .equals) }
        case .notEquals:
            return values.allSatisfy { !valueMatches($0, event: event, equalityOnly: true) }
        case .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual:
            return values.contains { numericValueMatches($0, event: event) }
        }
    }

    private func valueMatches(_ pattern: String, event: MacFSWFileEvent, equalityOnly: Bool) -> Bool {
        switch field {
        case .eventType:
            return enumMatches(pattern, event.eventType.rawValue)
        case .operationClass:
            return enumMatches(pattern, event.operationClass.rawValue)
        case .platformBinary:
            guard let expected = pattern.queryBool else {
                return MacFSWQueryMatcher.matches(pattern, in: event.queryValues(for: field), equalityOnly: equalityOnly)
            }
            return event.process.isPlatformBinary == expected
        case .mutation:
            guard let expected = pattern.queryBool else {
                return false
            }
            return event.eventType.isMutation == expected
        case .appleControlled:
            guard let expected = pattern.queryBool else {
                return false
            }
            return event.process.isAppleControlled == expected
        case .pid, .uid, .gid, .sequence, .timestamp, .esVersion, .flags:
            if pattern.containsWildcard {
                return MacFSWQueryMatcher.matches(pattern, in: event.queryValues(for: field), equalityOnly: true)
            }
            return MacFSWQueryMatcher.matches(pattern, in: event.queryValues(for: field), equalityOnly: true)
        default:
            return MacFSWQueryMatcher.matches(pattern, in: event.queryValues(for: field), equalityOnly: equalityOnly)
        }
    }

    private func enumMatches(_ pattern: String, _ value: String) -> Bool {
        if pattern.containsWildcard {
            return MacFSWQueryMatcher.matches(pattern, in: [value], equalityOnly: true)
        }
        return value.caseInsensitiveCompare(pattern) == .orderedSame
    }

    private func numericValueMatches(_ rawValue: String, event: MacFSWFileEvent) -> Bool {
        guard let expected = rawValue.queryNumber,
              let actual = event.queryNumber(for: field) else {
            return false
        }
        return compare(actual, expected)
    }

    private func compare(_ actual: Double, _ expected: Double) -> Bool {
        switch comparison {
        case .greaterThan:
            return actual > expected
        case .greaterOrEqual:
            return actual >= expected
        case .lessThan:
            return actual < expected
        case .lessOrEqual:
            return actual <= expected
        case .contains, .equals, .notEquals:
            return false
        }
    }
}

public enum MacFSWQueryComparison: String, Codable, Equatable, Sendable {
    case contains
    case equals
    case notEquals
    case greaterThan
    case greaterOrEqual
    case lessThan
    case lessOrEqual
}

public enum MacFSWQueryField: String, Codable, CaseIterable, Sendable {
    case any
    case eventType
    case operationClass
    case targetPath
    case sourcePath
    case path
    case processName
    case pid
    case executable
    case signingID
    case teamID
    case platformBinary
    case uid
    case gid
    case uidGid
    case eventID
    case sequence
    case timestamp
    case rawType
    case esVersion
    case flags
    case parameters
    case mutation
    case appleControlled
    case auditToken
    case cdhash
}

public enum MacFSWEventSortOrder: String, Codable, Equatable, Sendable {
    case newestFirst
    case oldestFirst
}

private enum MacFSWQueryMatcher {
    static func matches(_ pattern: String, in values: [String], equalityOnly: Bool = false) -> Bool {
        let normalized = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return true
        }

        return values.contains { value in
            let candidate = value.lowercased()
            if normalized.containsWildcard {
                return glob(normalized, matches: candidate)
            }
            if equalityOnly {
                return candidate == normalized
            }
            return candidate.localizedCaseInsensitiveContains(normalized)
        }
    }

    private static func glob(_ pattern: String, matches value: String) -> Bool {
        let pattern = Array(pattern)
        let value = Array(value)
        var patternIndex = 0
        var valueIndex = 0
        var starIndex: Int?
        var starValueIndex = 0

        while valueIndex < value.count {
            if patternIndex < pattern.count,
               (pattern[patternIndex] == "?" || pattern[patternIndex] == value[valueIndex]) {
                patternIndex += 1
                valueIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                starValueIndex = valueIndex
                patternIndex += 1
            } else if let starIndex {
                patternIndex = starIndex + 1
                starValueIndex += 1
                valueIndex = starValueIndex
            } else {
                return false
            }
        }

        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }

        return patternIndex == pattern.count
    }
}

private extension MacFSWFileEvent {
    var fullTextValues: [String] {
        [
            eventType.rawValue,
            operationClass.rawValue,
            targetPath,
            sourcePath,
            process.processName,
            String(process.pid),
            process.executablePath,
            process.signingID,
            process.teamID,
            process.isPlatformBinary ? "yes" : "no",
            process.isPlatformBinary ? "true" : "false",
            String(uid),
            String(gid),
            "\(uid)/\(gid)",
            id.uuidString,
            String(sequence),
            String(timestampNS),
            rawEventType,
            rawEventTypeValue.map { String($0) },
            String(rawEventVersion),
            String(flags),
            parameterText,
            operationDetailSummary,
            process.auditToken,
            process.cdhash,
        ].compactMap { $0 }.filter { !$0.isEmpty }
    }

    func queryValues(for field: MacFSWQueryField) -> [String] {
        switch field {
        case .any:
            return fullTextValues
        case .eventType:
            return [eventType.rawValue, rawEventType]
        case .operationClass:
            return [operationClass.rawValue]
        case .targetPath:
            return [targetPath]
        case .sourcePath:
            return [sourcePath].compactMap { $0 }
        case .path:
            return [targetPath, sourcePath].compactMap { $0 }
        case .processName:
            return [process.processName]
        case .pid:
            return [String(process.pid)]
        case .executable:
            return [process.executablePath]
        case .signingID:
            return [process.signingID].compactMap { $0 }
        case .teamID:
            return [process.teamID].compactMap { $0 }
        case .platformBinary:
            return process.isPlatformBinary.queryBoolValues
        case .uid:
            return [String(uid)]
        case .gid:
            return [String(gid)]
        case .uidGid:
            return ["\(uid)/\(gid)"]
        case .eventID:
            return [id.uuidString]
        case .sequence:
            return [String(sequence)]
        case .timestamp:
            return [String(timestampNS)]
        case .rawType:
            return [rawEventType, rawEventTypeValue.map { String($0) }].compactMap { $0 }
        case .esVersion:
            return [String(rawEventVersion)]
        case .flags:
            return [String(flags), "0x" + String(flags, radix: 16)]
        case .parameters:
            return parameters.flatMap { [$0.key, $0.label, $0.value, $0.displayText] } + [operationDetailSummary]
        case .mutation:
            return eventType.isMutation.queryBoolValues
        case .appleControlled:
            return process.isAppleControlled.queryBoolValues
        case .auditToken:
            return [process.auditToken]
        case .cdhash:
            return [process.cdhash].compactMap { $0 }
        }
    }

    func queryNumber(for field: MacFSWQueryField) -> Double? {
        switch field {
        case .pid:
            return Double(process.pid)
        case .uid:
            return Double(uid)
        case .gid:
            return Double(gid)
        case .sequence:
            return Double(sequence)
        case .timestamp:
            return Double(timestampNS)
        case .esVersion:
            return Double(rawEventVersion)
        case .flags:
            return Double(flags)
        default:
            return nil
        }
    }
}

private extension MacFSWProcessIdentity {
    var isAppleControlled: Bool {
        if isPlatformBinary {
            return true
        }
        if let signingID, signingID.lowercased().hasPrefix("com.apple.") {
            return true
        }
        return false
    }
}

private extension Bool {
    var queryBoolValues: [String] {
        self ? ["true", "yes", "1", "on"] : ["false", "no", "0", "off"]
    }
}

extension String {
    var normalizedQueryKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var containsWildcard: Bool {
        contains("*") || contains("?")
    }

    var queryBool: Bool? {
        switch trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return nil
        }
    }

    var queryNumber: Double? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("0x"), let value = UInt64(trimmed.dropFirst(2), radix: 16) {
            return Double(value)
        }
        return Double(trimmed)
    }
}
