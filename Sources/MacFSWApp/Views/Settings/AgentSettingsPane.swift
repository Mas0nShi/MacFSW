import AppKit
import SwiftUI

/// Points users at the `macfsw` tool bundled next to the app executable
/// and how to register it as an MCP server. The tool runs on its own; it
/// does not talk to this app.
struct AgentSettingsPane: View {
    private let cliURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/macfsw")

    var body: some View {
        Form {
            Section("Command Line") {
                if FileManager.default.isExecutableFile(atPath: cliURL.path) {
                    CopyableCommand(text: cliURL.path)
                    Text("Record and query sessions from Terminal. Run it with --help for the subcommands.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("The macfsw tool ships inside the packaged MacFSW.app. Run Scripts/package-dev-app.sh to build it.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("AI Agents (MCP)") {
                CopyableCommand(text: "claude mcp add macfsw -- \(shellQuoted(cliURL.path)) mcp")
                Text("Registers MacFSW with Claude Code. Other MCP clients can launch `\(cliURL.path) mcp` as a stdio server.")
                    .foregroundStyle(.secondary)
                Text("Agents record and query their own sessions and can start and stop recording. To hand an agent a recording made here, save it and ask the agent to open the file.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }

    private func shellQuoted(_ path: String) -> String {
        path.contains(" ") ? "'\(path)'" : path
    }
}

private struct CopyableCommand: View {
    let text: String

    var body: some View {
        HStack {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .help("Copy")
        }
    }
}
