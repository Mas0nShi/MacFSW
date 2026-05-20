import Foundation
import GRDB

enum MacFSWSQLValue: Sendable {
    case null
    case int64(Int64)
    case double(Double)
    case string(String)

    init(_ value: Int) {
        self = .int64(Int64(value))
    }

    init(_ value: Int32) {
        self = .int64(Int64(value))
    }

    init(_ value: Int64) {
        self = .int64(value)
    }

    init(_ value: UInt64) {
        self = .int64(Int64(bitPattern: value))
    }

    init(_ value: Double) {
        self = .double(value)
    }

    init(_ value: String) {
        self = .string(value)
    }

    var databaseValue: DatabaseValue {
        switch self {
        case .null:
            .null
        case .int64(let value):
            value.databaseValue
        case .double(let value):
            value.databaseValue
        case .string(let value):
            value.databaseValue
        }
    }
}

struct MacFSWCompiledSQL: Sendable {
    var whereSQL: String
    var arguments: [MacFSWSQLValue]

    static var all: MacFSWCompiledSQL {
        MacFSWCompiledSQL(whereSQL: "1", arguments: [])
    }
}

enum MacFSWSQLQueryCompiler {
    static func compile(_ query: MacFSWEventQuery) -> MacFSWCompiledSQL {
        var clauses: [MacFSWCompiledSQL] = []
        clauses.append(contentsOf: legacyClauses(for: query, includeText: query.expression == nil))
        if let expression = query.expression {
            clauses.append(compile(expression))
        }
        return and(clauses)
    }

    static func arguments(_ values: [MacFSWSQLValue]) -> StatementArguments {
        StatementArguments(values.map(\.databaseValue))
    }

    static func visibleWindow(totalCount: Int, limit: Int, requestedRange: Range<Int>) -> (offset: Int, limit: Int) {
        let visibleCount = visibleCount(totalCount: totalCount, limit: limit)
        let windowStart = max(0, totalCount - visibleCount)
        let lowerBound = max(0, min(visibleCount, requestedRange.lowerBound))
        let upperBound = max(lowerBound, min(visibleCount, requestedRange.upperBound))
        return (windowStart + lowerBound, upperBound - lowerBound)
    }

    static func visibleCount(totalCount: Int, limit: Int) -> Int {
        let totalCount = max(0, totalCount)
        guard limit > 0 else {
            return totalCount
        }
        return min(totalCount, limit)
    }

    static func orderClause(_ sortOrder: MacFSWEventSortOrder) -> String {
        switch sortOrder {
        case .oldestFirst:
            "timestampNS ASC, sequence ASC"
        case .newestFirst:
            "timestampNS DESC, sequence DESC"
        }
    }

    static func orderBoundClause(
        for event: MacFSWFileEvent,
        sortOrder: MacFSWEventSortOrder
    ) -> MacFSWCompiledSQL {
        switch sortOrder {
        case .oldestFirst:
            MacFSWCompiledSQL(
                whereSQL: "(timestampNS < ? OR (timestampNS = ? AND sequence <= ?))",
                arguments: [
                    MacFSWSQLValue(event.timestampNS),
                    MacFSWSQLValue(event.timestampNS),
                    MacFSWSQLValue(event.sequence),
                ]
            )
        case .newestFirst:
            MacFSWCompiledSQL(
                whereSQL: "(timestampNS > ? OR (timestampNS = ? AND sequence >= ?))",
                arguments: [
                    MacFSWSQLValue(event.timestampNS),
                    MacFSWSQLValue(event.timestampNS),
                    MacFSWSQLValue(event.sequence),
                ]
            )
        }
    }

    private static func legacyClauses(for query: MacFSWEventQuery, includeText: Bool) -> [MacFSWCompiledSQL] {
        var clauses: [MacFSWCompiledSQL] = []
        if let startTimeNS = query.startTimeNS {
            clauses.append(simple("timestampNS >= ?", MacFSWSQLValue(startTimeNS)))
        }
        if let endTimeNS = query.endTimeNS {
            clauses.append(simple("timestampNS <= ?", MacFSWSQLValue(endTimeNS)))
        }
        if query.mutationOnly {
            clauses.append(simple("mutation = ?", MacFSWSQLValue(1)))
        }
        if query.sensitiveOnly {
            clauses.append(simple("sensitive = ?", MacFSWSQLValue(1)))
        }
        if let minimumRisk = query.minimumRisk {
            clauses.append(simple("riskScore >= ?", MacFSWSQLValue(minimumRisk.score)))
        }
        if let processIdentity = query.processIdentity {
            clauses.append(processIdentityClause(processIdentity))
        }
        if !query.pids.isEmpty {
            clauses.append(inClause("pid", values: query.pids.map { MacFSWSQLValue($0) }))
        }
        if !query.eventTypes.isEmpty {
            clauses.append(inClause("eventType", values: query.eventTypes.map { MacFSWSQLValue($0.rawValue) }))
        }
        if !query.operationClasses.isEmpty {
            clauses.append(inClause("operationClass", values: query.operationClasses.map { MacFSWSQLValue($0.rawValue) }))
        }
        if let processText = query.processText, !processText.isBlankSQL {
            clauses.append(textClause(pattern: processText, columns: ["processName", "executablePath"]))
        }
        if let executableText = query.executableText, !executableText.isBlankSQL {
            clauses.append(textClause(pattern: executableText, columns: ["executablePath"]))
        }
        if let pathText = query.pathText, !pathText.isBlankSQL {
            clauses.append(textClause(pattern: pathText, columns: ["targetPath", "sourcePath"]))
        }
        if let signingText = query.signingText, !signingText.isBlankSQL {
            clauses.append(textClause(pattern: signingText, columns: ["signingID"]))
        }
        for excludedTeamText in query.excludedTeamTexts where !excludedTeamText.isBlankSQL {
            clauses.append(not(textClause(pattern: excludedTeamText, columns: ["teamID"])))
        }
        if let teamText = query.teamText, !teamText.isBlankSQL {
            clauses.append(textClause(pattern: teamText, columns: ["teamID"]))
        }
        if let appleControlled = query.appleControlled {
            clauses.append(simple("appleControlled = ?", MacFSWSQLValue(appleControlled ? 1 : 0)))
        }
        if let platformBinary = query.platformBinary {
            clauses.append(simple("isPlatformBinary = ?", MacFSWSQLValue(platformBinary ? 1 : 0)))
        }
        for excludedTerm in query.excludedTerms where !excludedTerm.isBlankSQL {
            clauses.append(not(textClause(pattern: excludedTerm, columns: anyTextColumns)))
        }
        if includeText, !query.text.isBlankSQL {
            clauses.append(textClause(pattern: query.text, columns: anyTextColumns))
        }
        return clauses
    }

    private static func compile(_ expression: MacFSWQueryExpression) -> MacFSWCompiledSQL {
        switch expression {
        case .predicate(let predicate):
            compile(predicate)
        case .not(let expression):
            not(compile(expression))
        case .and(let expressions):
            and(expressions.map(compile))
        case .or(let expressions):
            or(expressions.map(compile))
        }
    }

    private static func compile(_ predicate: MacFSWQueryPredicate) -> MacFSWCompiledSQL {
        let values = predicate.values.filter { !$0.isBlankSQL }
        guard !values.isEmpty else {
            return .all
        }

        switch predicate.comparison {
        case .contains:
            return or(values.map { containsClause(field: predicate.field, pattern: $0) })
        case .equals:
            return or(values.map { equalityClause(field: predicate.field, pattern: $0) })
        case .notEquals:
            return and(values.map { not(equalityClause(field: predicate.field, pattern: $0)) })
        case .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual:
            return or(values.map { numericClause(field: predicate.field, rawValue: $0, comparison: predicate.comparison) })
        }
    }

    private static func containsClause(field: MacFSWQueryField, pattern: String) -> MacFSWCompiledSQL {
        switch field {
        case .eventType:
            return enumClause(columns: ["eventType", "rawEventType"], pattern: pattern)
        case .operationClass:
            return enumClause(columns: ["operationClass"], pattern: pattern)
        case .risk:
            return enumClause(columns: ["risk"], pattern: pattern)
        case .platformBinary:
            if let expected = pattern.queryBoolSQL {
                return simple("isPlatformBinary = ?", MacFSWSQLValue(expected ? 1 : 0))
            }
            return textClause(pattern: pattern, columns: ["isPlatformBinaryText"])
        case .mutation:
            guard let expected = pattern.queryBoolSQL else {
                return falseClause()
            }
            return simple("mutation = ?", MacFSWSQLValue(expected ? 1 : 0))
        case .sensitive:
            guard let expected = pattern.queryBoolSQL else {
                return falseClause()
            }
            return simple("sensitive = ?", MacFSWSQLValue(expected ? 1 : 0))
        case .appleControlled:
            guard let expected = pattern.queryBoolSQL else {
                return falseClause()
            }
            return simple("appleControlled = ?", MacFSWSQLValue(expected ? 1 : 0))
        case .pid, .uid, .gid, .sequence, .timestamp, .esVersion, .flags:
            return equalityClause(field: field, pattern: pattern)
        default:
            return textClause(pattern: pattern, columns: columns(for: field))
        }
    }

    private static func equalityClause(field: MacFSWQueryField, pattern: String) -> MacFSWCompiledSQL {
        if pattern.containsWildcardSQL {
            return textClause(pattern: pattern, columns: columns(for: field), equalityOnly: true)
        }

        switch field {
        case .risk:
            return enumEqualityClause(column: "risk", pattern: pattern)
        case .eventType:
            return or([
                enumEqualityClause(column: "eventType", pattern: pattern),
                enumEqualityClause(column: "rawEventType", pattern: pattern),
            ])
        case .operationClass:
            return enumEqualityClause(column: "operationClass", pattern: pattern)
        case .auditToken:
            return simple("auditToken = ?", MacFSWSQLValue(pattern))
        case .platformBinary:
            if let expected = pattern.queryBoolSQL {
                return simple("isPlatformBinary = ?", MacFSWSQLValue(expected ? 1 : 0))
            }
            return textClause(pattern: pattern, columns: ["isPlatformBinaryText"], equalityOnly: true)
        case .mutation:
            guard let expected = pattern.queryBoolSQL else {
                return falseClause()
            }
            return simple("mutation = ?", MacFSWSQLValue(expected ? 1 : 0))
        case .sensitive:
            guard let expected = pattern.queryBoolSQL else {
                return falseClause()
            }
            return simple("sensitive = ?", MacFSWSQLValue(expected ? 1 : 0))
        case .appleControlled:
            guard let expected = pattern.queryBoolSQL else {
                return falseClause()
            }
            return simple("appleControlled = ?", MacFSWSQLValue(expected ? 1 : 0))
        default:
            return textClause(pattern: pattern, columns: columns(for: field), equalityOnly: true)
        }
    }

    private static func numericClause(
        field: MacFSWQueryField,
        rawValue: String,
        comparison: MacFSWQueryComparison
    ) -> MacFSWCompiledSQL {
        let op: String
        switch comparison {
        case .greaterThan: op = ">"
        case .greaterOrEqual: op = ">="
        case .lessThan: op = "<"
        case .lessOrEqual: op = "<="
        case .contains, .equals, .notEquals:
            return falseClause()
        }

        if field == .risk {
            guard let risk = MacFSWRiskLevel(rawValue: rawValue.lowercased()) else {
                return falseClause()
            }
            return simple("riskScore \(op) ?", MacFSWSQLValue(risk.score))
        }

        guard let number = rawValue.queryNumberSQL, let column = numericColumn(for: field) else {
            return falseClause()
        }
        return simple("\(column) \(op) ?", MacFSWSQLValue(number))
    }

    private static func enumClause(columns: [String], pattern: String) -> MacFSWCompiledSQL {
        if pattern.containsWildcardSQL {
            return textClause(pattern: pattern, columns: columns, equalityOnly: true)
        }
        return or(columns.map { enumEqualityClause(column: $0, pattern: pattern) })
    }

    private static func enumEqualityClause(column: String, pattern: String) -> MacFSWCompiledSQL {
        switch column {
        case "eventType", "operationClass", "risk":
            return simple("\(column) = ?", MacFSWSQLValue(pattern.lowercased()))
        default:
            return simple("lower(\(column)) = lower(?)", MacFSWSQLValue(pattern))
        }
    }

    private static func textClause(
        pattern: String,
        columns: [String],
        equalityOnly: Bool = false
    ) -> MacFSWCompiledSQL {
        guard !columns.isEmpty else {
            return falseClause()
        }

        let sqlPattern: String
        if pattern.containsWildcardSQL {
            sqlPattern = pattern.sqlLikePatternFromGlob
        } else if equalityOnly {
            sqlPattern = pattern.sqlLikeEscaped
        } else {
            sqlPattern = "%\(pattern.sqlLikeEscaped)%"
        }

        let likeClause = or(columns.map { column in
            MacFSWCompiledSQL(
                whereSQL: "lower(coalesce(\(column), '')) LIKE lower(?) ESCAPE '\\'",
                arguments: [MacFSWSQLValue(sqlPattern)]
            )
        })
        guard !pattern.containsWildcardSQL, !equalityOnly, let ftsColumn = ftsColumn(for: columns) else {
            return likeClause
        }
        return or([ftsClause(pattern: pattern, column: ftsColumn), likeClause])
    }

    private static func processIdentityClause(_ identity: MacFSWProcessFilterIdentity) -> MacFSWCompiledSQL {
        simple("pid = ?", MacFSWSQLValue(identity.pid))
    }

    private static func columns(for field: MacFSWQueryField) -> [String] {
        switch field {
        case .any:
            return anyTextColumns
        case .eventType:
            return ["eventType", "rawEventType"]
        case .operationClass:
            return ["operationClass"]
        case .targetPath:
            return ["targetPath"]
        case .sourcePath:
            return ["sourcePath"]
        case .path:
            return ["targetPath", "sourcePath"]
        case .processName:
            return ["processName"]
        case .pid:
            return ["pidText"]
        case .executable:
            return ["executablePath"]
        case .signingID:
            return ["signingID"]
        case .teamID:
            return ["teamID"]
        case .platformBinary:
            return ["isPlatformBinaryText"]
        case .risk:
            return ["risk"]
        case .riskReasons:
            return ["riskReasonsText"]
        case .uid:
            return ["uidText"]
        case .gid:
            return ["gidText"]
        case .uidGid:
            return ["uidGidText"]
        case .eventID:
            return ["id"]
        case .sequence:
            return ["sequenceText"]
        case .timestamp:
            return ["timestampText"]
        case .rawType:
            return ["rawEventType", "rawEventTypeValueText"]
        case .esVersion:
            return ["rawEventVersionText"]
        case .flags:
            return ["flagsText", "flagsHexText"]
        case .parameters:
            return ["parameterText", "detailSummary"]
        case .mutation:
            return ["mutationText"]
        case .sensitive:
            return ["sensitiveText"]
        case .appleControlled:
            return ["appleControlledText"]
        case .auditToken:
            return ["auditToken"]
        case .cdhash:
            return ["cdhash"]
        }
    }

    private static func numericColumn(for field: MacFSWQueryField) -> String? {
        switch field {
        case .pid:
            return "pid"
        case .uid:
            return "uid"
        case .gid:
            return "gid"
        case .sequence:
            return "sequence"
        case .timestamp:
            return "timestampNS"
        case .esVersion:
            return "rawEventVersion"
        case .flags:
            return "CAST(flagsText AS REAL)"
        default:
            return nil
        }
    }

    private static var anyTextColumns: [String] {
        [
            "eventType",
            "operationClass",
            "targetPath",
            "sourcePath",
            "processName",
            "pidText",
            "executablePath",
            "signingID",
            "teamID",
            "isPlatformBinaryText",
            "risk",
            "riskReasonsText",
            "uidText",
            "gidText",
            "uidGidText",
            "id",
            "sequenceText",
            "timestampText",
            "rawEventType",
            "rawEventTypeValueText",
            "rawEventVersionText",
            "flagsText",
            "parameterText",
            "detailSummary",
            "auditToken",
            "cdhash",
        ]
    }

    private static func ftsColumn(for columns: [String]) -> String? {
        switch Set(columns) {
        case Set(anyTextColumns):
            return "any_text"
        case Set(["processName"]):
            return "process_text"
        case Set(["executablePath"]):
            return "executable_text"
        case Set(["targetPath", "sourcePath"]):
            return "path_text"
        case Set(["signingID"]):
            return "signing_text"
        case Set(["teamID"]):
            return "team_text"
        case Set(["riskReasonsText"]):
            return "risk_reason_text"
        default:
            return nil
        }
    }

    private static func ftsClause(pattern: String, column: String) -> MacFSWCompiledSQL {
        MacFSWCompiledSQL(
            whereSQL: "sequence IN (SELECT rowid FROM event_fts WHERE \(column) MATCH ?)",
            arguments: [MacFSWSQLValue(pattern.fts5Quoted)]
        )
    }

    private static func simple(_ sql: String, _ value: MacFSWSQLValue) -> MacFSWCompiledSQL {
        MacFSWCompiledSQL(whereSQL: sql, arguments: [value])
    }

    private static func inClause(_ column: String, values: [MacFSWSQLValue]) -> MacFSWCompiledSQL {
        guard !values.isEmpty else {
            return .all
        }
        return MacFSWCompiledSQL(
            whereSQL: "\(column) IN (\(Array(repeating: "?", count: values.count).joined(separator: ", ")))",
            arguments: values
        )
    }

    private static func and(_ clauses: [MacFSWCompiledSQL]) -> MacFSWCompiledSQL {
        combine(clauses, separator: " AND ", empty: .all)
    }

    private static func or(_ clauses: [MacFSWCompiledSQL]) -> MacFSWCompiledSQL {
        combine(clauses, separator: " OR ", empty: falseClause())
    }

    private static func not(_ clause: MacFSWCompiledSQL) -> MacFSWCompiledSQL {
        MacFSWCompiledSQL(whereSQL: "NOT (\(clause.whereSQL))", arguments: clause.arguments)
    }

    private static func falseClause() -> MacFSWCompiledSQL {
        MacFSWCompiledSQL(whereSQL: "0", arguments: [])
    }

    private static func combine(
        _ clauses: [MacFSWCompiledSQL],
        separator: String,
        empty: MacFSWCompiledSQL
    ) -> MacFSWCompiledSQL {
        let clauses = clauses.filter { $0.whereSQL != "1" }
        guard !clauses.isEmpty else {
            return empty
        }
        return MacFSWCompiledSQL(
            whereSQL: clauses.map { "(\($0.whereSQL))" }.joined(separator: separator),
            arguments: clauses.flatMap(\.arguments)
        )
    }
}

private extension String {
    var isBlankSQL: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var containsWildcardSQL: Bool {
        contains("*") || contains("?")
    }

    var sqlLikeEscaped: String {
        var escaped = ""
        for character in self {
            switch character {
            case "%", "_", "\\":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    var sqlLikePatternFromGlob: String {
        var escaped = ""
        for character in self {
            switch character {
            case "*":
                escaped.append("%")
            case "?":
                escaped.append("_")
            case "%", "_", "\\":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    var queryBoolSQL: Bool? {
        switch trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return nil
        }
    }

    var queryNumberSQL: Double? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("0x"), let value = UInt64(trimmed.dropFirst(2), radix: 16) {
            return Double(value)
        }
        return Double(trimmed)
    }

    var fts5Quoted: String {
        "\"\(replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
