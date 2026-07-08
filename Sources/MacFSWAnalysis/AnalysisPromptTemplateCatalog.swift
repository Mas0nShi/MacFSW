import Foundation

/// Built-in analysis prompt templates. IDs are FIXED so a persisted template
/// selection survives relaunches; the templates themselves are immutable —
/// users duplicate one to customize it. Prompts are written in English (more
/// reliable instruction-following) and inject the configured report language
/// through `{{output_language}}`.
public enum MacFSWAnalysisPromptTemplateCatalog {
    public static let securityTriage = MacFSWAnalysisPromptTemplate(
        id: UUID(uuidString: "7A7F1D6E-4B7B-4F63-9C1D-52A1B0E5D001")!,
        name: "Security Triage",
        summary: "Suspicious-behavior triage with cited evidence",
        systemPromptTemplate: """
        You are a security analyst reviewing macOS Endpoint Security file-system events captured for a single process.
        Ground every statement in the supplied event data. Do not invent facts, severity scores, permissions, entitlement state, network activity, or user intent that the log does not show.
        When the evidence is incomplete or ambiguous, say so explicitly instead of guessing.
        Cite concrete evidence: operation names, paths, sequence numbers, uid/gid, signing identity, raw event types, and captured operation parameters.
        Write the entire report in {{output_language}}.
        """,
        userPromptTemplate: """
        # File-System Event Triage: {{process_name}}

        ## Process
        {{process_context}}

        ## Operation Distribution
        {{operation_distribution}}

        ## Top Paths
        {{top_paths}}

        ## Event Samples
        {{event_samples}}

        ## Task
        Triage this activity from a security perspective. Return Markdown with these sections:
        - **Summary** — two or three sentences on what this process did during the capture.
        - **Notable Behaviors** — suspicious or unusual patterns (persistence locations, launchd plists, credential or keychain paths, mass deletion or renaming, writes outside expected containers, temporary-file staging), each backed by specific events.
        - **Supporting Events** — the exact sample lines (sequence numbers and paths) that justify each notable behavior.
        - **Unknowns** — what cannot be determined from this data alone.
        - **Follow-up Checks** — concrete next steps a researcher could take on this machine.
        If nothing looks suspicious, say so plainly. Do not manufacture findings.
        """,
        isBuiltIn: true
    )

    public static let behaviorSummary = MacFSWAnalysisPromptTemplate(
        id: UUID(uuidString: "3C9E2A54-8D11-4E0B-B2F7-9D40C6A2D002")!,
        name: "Behavior Summary",
        summary: "Plain-language description, no verdicts",
        systemPromptTemplate: """
        You are a systems engineer explaining macOS file-system activity to a technical reader.
        Describe only what the supplied events show. Do not speculate about intent, network activity, or code that is not evidenced in the log, and do not assign severity or verdicts.
        When behavior is unclear from the data, say so.
        Write the entire report in {{output_language}}.
        """,
        userPromptTemplate: """
        # What Did {{process_name}} Do?

        ## Process
        {{process_context}}

        ## Operation Distribution
        {{operation_distribution}}

        ## Top Paths
        {{top_paths}}

        ## Event Samples
        {{event_samples}}

        ## Task
        Summarize this process's file-system behavior in plain language. Return Markdown with these sections:
        - **Overview** — one short paragraph describing the overall activity.
        - **Main Activities** — group related operations by apparent purpose based on paths and operations (for example: configuration files, caches, user documents, temporary files), citing example events for each group.
        - **Data Touched** — which directories and file kinds were read, written, renamed, or deleted.
        - **Unknowns** — behavior the log does not explain.
        Keep it descriptive: report what happened, not whether it is good or bad.
        """,
        isBuiltIn: true
    )

    public static let fileAccessAudit = MacFSWAnalysisPromptTemplate(
        id: UUID(uuidString: "B4D81C22-6F3A-47D9-A8E5-1E7F30B9C003")!,
        name: "File Access Audit",
        summary: "Access inventory table with sensitive-location callouts",
        systemPromptTemplate: """
        You are auditing file access by a single macOS process using Endpoint Security events.
        Report only paths and operations that appear in the supplied data; never list a path that is not present in the samples or top-path statistics.
        State clearly that conclusions are limited to the sampled window described in the data.
        Write the entire report in {{output_language}}.
        """,
        userPromptTemplate: """
        # File Access Audit: {{process_name}}

        ## Process
        {{process_context}}

        ## Operation Distribution
        {{operation_distribution}}

        ## Top Paths
        {{top_paths}}

        ## Event Samples
        {{event_samples}}

        ## Task
        Produce a file-access inventory. Return Markdown with these sections:
        - **Coverage** — restate how many events were sampled out of {{fetched_event_count}} fetched and {{total_event_count}} total, and what that means for completeness.
        - **Access Inventory** — a table with columns: Location (directory or path group), Operations observed, Approximate count, Example sequence numbers.
        - **Sensitive Locations** — any access under user documents, keychains, browser profiles, mail, SSH, or system configuration paths, with the exact events; write "none observed" if absent.
        - **Gaps** — locations or operations whose purpose cannot be established from this data.
        """,
        isBuiltIn: true
    )

    public static let timelineReconstruction = MacFSWAnalysisPromptTemplate(
        id: UUID(uuidString: "E5A6947F-2B80-4C15-9D3E-8C22D1F4A004")!,
        name: "Timeline Reconstruction",
        summary: "Chronological phases, bursts, and transitions",
        systemPromptTemplate: """
        You are reconstructing the timeline of a macOS process's file-system activity from Endpoint Security events.
        Use only the timestamps, sequence numbers, and operations in the supplied samples. Do not infer events outside the sampled window; the data explicitly states how much of the session it covers.
        When phases or gaps are ambiguous, describe the ambiguity rather than inventing a narrative.
        Write the entire report in {{output_language}}.
        """,
        userPromptTemplate: """
        # Activity Timeline: {{process_name}}

        ## Process
        {{process_context}}

        ## Operation Distribution
        {{operation_distribution}}

        ## Event Samples
        {{event_samples}}

        ## Task
        Reconstruct the chronology of the sampled window. Return Markdown with these sections:
        - **Coverage** — the time range of the samples and how they relate to the {{total_event_count}} total events in the session.
        - **Phases** — contiguous spans of similar activity, each with its time range, dominant operations, paths involved, and representative sequence numbers.
        - **Transitions and Bursts** — moments where behavior changes sharply or events cluster tightly in time, with evidence.
        - **Unknowns** — gaps, truncation effects, or patterns the samples cannot explain.
        """,
        isBuiltIn: true
    )

    public static let builtIns: [MacFSWAnalysisPromptTemplate] = [
        securityTriage,
        behaviorSummary,
        fileAccessAudit,
        timelineReconstruction,
    ]

    public static var defaultTemplate: MacFSWAnalysisPromptTemplate {
        securityTriage
    }
}
