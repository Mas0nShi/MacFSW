import Foundation

public struct MacFSWAnalysisPromptTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var summary: String
    public var systemPromptTemplate: String
    public var userPromptTemplate: String
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        systemPromptTemplate: String,
        userPromptTemplate: String,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.systemPromptTemplate = systemPromptTemplate
        self.userPromptTemplate = userPromptTemplate
        self.isBuiltIn = isBuiltIn
    }
}

public struct MacFSWPromptPlaceholder: Equatable, Sendable, Identifiable {
    /// Bare name, e.g. "event_samples".
    public var name: String
    public var summary: String

    /// The literal token to place in a template, e.g. "{{event_samples}}".
    public var token: String { "{{\(name)}}" }
    public var id: String { name }

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }
}

/// Dumb `{{key}}` substitution — no logic, no loops. Data sections are
/// pre-rendered by the payload builder; unknown placeholders stay verbatim
/// so typos are visible in the outgoing prompt (the template editor warns
/// about them live).
public enum MacFSWPromptTemplateRenderer {
    public static let knownPlaceholders: [MacFSWPromptPlaceholder] = [
        MacFSWPromptPlaceholder(
            name: "process_context",
            summary: "Process identity plus total/fetched/sampled event counts"
        ),
        MacFSWPromptPlaceholder(
            name: "operation_distribution",
            summary: "Per-operation event counts over all fetched events"
        ),
        MacFSWPromptPlaceholder(
            name: "top_paths",
            summary: "Most frequent paths (up to 24) over all fetched events"
        ),
        MacFSWPromptPlaceholder(
            name: "event_samples",
            summary: "Sampled event lines, prefixed by a coverage statement"
        ),
        MacFSWPromptPlaceholder(
            name: "total_event_count",
            summary: "Total events for the process in this session"
        ),
        MacFSWPromptPlaceholder(
            name: "fetched_event_count",
            summary: "Events fetched from the store (Max Events setting)"
        ),
        MacFSWPromptPlaceholder(
            name: "sampled_event_count",
            summary: "Events actually included in the prompt"
        ),
        MacFSWPromptPlaceholder(
            name: "process_name",
            summary: "Process display name, for headings"
        ),
        MacFSWPromptPlaceholder(
            name: "output_language",
            summary: "The configured report language, e.g. Simplified Chinese"
        ),
    ]

    public static func render(_ template: String, substitutions: [String: String]) -> String {
        var rendered = template
        for (name, value) in substitutions {
            rendered = rendered.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return rendered
    }

    public static func placeholderNames(in template: String) -> Set<String> {
        var names: Set<String> = []
        var searchRange = template.startIndex..<template.endIndex
        while let match = template.range(
            of: #"\{\{([a-z_]+)\}\}"#,
            options: .regularExpression,
            range: searchRange
        ) {
            let inner = template[match]
                .dropFirst(2)
                .dropLast(2)
            names.insert(String(inner))
            searchRange = match.upperBound..<template.endIndex
        }
        return names
    }

    public static func unknownPlaceholderNames(in template: String) -> Set<String> {
        placeholderNames(in: template).subtracting(knownPlaceholders.map(\.name))
    }
}
