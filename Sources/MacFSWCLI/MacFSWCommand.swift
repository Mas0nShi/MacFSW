import ArgumentParser
import Foundation
import MacFSWCommands
import MacFSWCore

@main
struct MacFSWCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macfsw",
        abstract: "Record and query macOS file-system activity without the MacFSW app.",
        discussion: """
        Recording needs the MacFSW Endpoint Extension, enabled and approved from \
        the MacFSW app once. Querying saved .macfsw-session files needs nothing.

        Queries use the same language as the app's command bar, for example:
          macfsw query run.macfsw-session 'path:/Library/LaunchAgents mutation:true'
        """,
        version: Bundle.main.macfswVersion,
        subcommands: [
            StatusCommand.self,
            SetupCommand.self,
            RecordCommand.self,
            QueryCommand.self,
            ProcessesCommand.self,
            SummaryCommand.self,
            EventCommand.self,
            MCPCommand.self,
        ]
    )

    static func makeWorkspace() -> Workspace {
        Workspace(
            client: makeClient(),
            appVersion: Bundle.main.macfswVersion,
            inspector: makeInspector()
        )
    }

    static func makeClient() -> MacFSWXPCCaptureClient {
        MacFSWXPCCaptureClient(serviceName: Bundle.main.macfswXPCServiceName, healthTimeoutSeconds: 3)
    }

    static func makeInspector() -> ExtensionInspector {
        ExtensionInspector(
            bundledVersion: Bundle.main.bundledEndpointExtensionVersion,
            activatedVersion: { SystemExtensionsList.activatedVersion(of: MacFSWXPCDefaults.extensionBundleIdentifier) }
        )
    }
}

struct OutputOptions: ParsableArguments {
    @Flag(help: "Print JSON instead of text.")
    var json = false
}

struct SessionFileArgument: ParsableArguments {
    @Argument(help: "A saved .macfsw-session file.", completion: .file(extensions: [MacFSWSessionArchive.nativeExtension]))
    var session: String

    func open() async throws -> Workspace {
        let workspace = MacFSWCommand.makeWorkspace()
        _ = try await workspace.open(URL(fileURLWithPath: session))
        return workspace
    }
}

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check whether the Endpoint Extension can record."
    )

    @OptionGroup var output: OutputOptions

    func run() async throws {
        let status = await MacFSWCommand.makeWorkspace().status()
        try Output.print(status, json: output.json)
    }
}

struct QueryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "List events matching a query."
    )

    @OptionGroup var file: SessionFileArgument
    @Argument(help: "A MacFSW query; omit to list every event.")
    var query = ""
    @Option(help: "Events to return, at most \(SessionQueries.maxLimit).")
    var limit = 100
    @Option(help: "Matching events to skip first.")
    var offset = 0
    @Flag(help: "Newest events first.")
    var newest = false
    @OptionGroup var output: OutputOptions

    func run() async throws {
        let page = try await file.open().queries()
            .events(matching: query, limit: limit, offset: offset, order: newest ? .newest : .oldest)
        try Output.print(page, json: output.json)
    }
}

struct ProcessesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "processes",
        abstract: "List processes with events matching a query."
    )

    @OptionGroup var file: SessionFileArgument
    @Argument(help: "A MacFSW query; omit to list every process.")
    var query = ""
    @Option(help: "Processes to return, at most \(SessionQueries.maxLimit).")
    var limit = 100
    @OptionGroup var output: OutputOptions

    func run() async throws {
        let list = try await file.open().queries().processes(matching: query, limit: limit)
        try Output.print(list, json: output.json)
    }
}

struct SummaryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summary",
        abstract: "Count operations and the busiest processes for a query."
    )

    @OptionGroup var file: SessionFileArgument
    @Argument(help: "A MacFSW query; omit to summarize the whole session.")
    var query = ""
    @Option(help: "Entries per top-N list.")
    var top = 10
    @OptionGroup var output: OutputOptions

    func run() async throws {
        let summary = try await file.open().queries().summary(matching: query, top: top)
        try Output.print(summary, json: output.json)
    }
}

struct EventCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "event",
        abstract: "Show every recorded field of one event."
    )

    @OptionGroup var file: SessionFileArgument
    @Argument(help: "The event id, as printed by `macfsw query`.")
    var id: String

    func run() async throws {
        guard let uuid = UUID(uuidString: id) else {
            throw ValidationError("'\(id)' is not an event id.")
        }
        let event = try await file.open().queries().event(id: uuid)
        try Output.print(event, json: true)
    }
}
