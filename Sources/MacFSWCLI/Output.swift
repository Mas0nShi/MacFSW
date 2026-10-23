import Foundation
import MacFSWCommands
import MacFSWCore

enum Output {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func print<T: Encodable>(_ value: T, json: Bool) throws {
        if !json, let renderable = value as? any TextRenderable {
            Swift.print(renderable.text)
        } else {
            Swift.print(String(decoding: try encoder.encode(value), as: UTF8.self))
        }
    }

    static func time(_ date: Date) -> String {
        date.formatted(.iso8601.time(includingFractionalSeconds: true))
    }
}

protocol TextRenderable {
    var text: String { get }
}

extension EventPage: TextRenderable {
    var text: String {
        var lines = diagnostics.map { "warning: \($0)" }
        let shown = events.isEmpty ? "none" : "\(offset + 1)–\(offset + events.count)"
        lines.append("\(total) events match \(query.isEmpty ? "(everything)" : query); showing \(shown)")
        for event in events {
            let source = event.sourcePath.map { "\($0) -> " } ?? ""
            lines.append("\(Output.time(event.time))  \(event.operation.padding(toLength: 10, withPad: " ", startingAt: 0))  \(event.process)(\(event.pid))  \(source)\(event.path)  \(event.id.uuidString)")
        }
        return lines.joined(separator: "\n")
    }
}

extension ProcessList: TextRenderable {
    var text: String {
        var lines = diagnostics.map { "warning: \($0)" }
        lines.append("\(total) processes")
        for process in processes {
            let signing = process.signing.isEmpty ? "unsigned" : process.signing
            lines.append("\(String(process.events).leftPadded(to: 7))  \(process.name)(\(process.pid))  \(signing)  \(process.executable)")
        }
        return lines.joined(separator: "\n")
    }
}

extension EventSummary: TextRenderable {
    var text: String {
        var lines = diagnostics.map { "warning: \($0)" }
        lines.append("\(total) events match \(query.isEmpty ? "(everything)" : query)")
        for (title, values) in [("Operations", operations), ("Processes", topProcesses), ("Executables", topExecutables), ("Signing IDs", topSigningIDs)] where !values.isEmpty {
            lines.append("")
            lines.append(title)
            lines += values.map { "\(String($0.count).leftPadded(to: 7))  \($0.value)" }
        }
        return lines.joined(separator: "\n")
    }
}

extension Status: TextRenderable {
    var text: String {
        var lines = [self.extension.text]
        if let session {
            lines.append(session.text)
        }
        return lines.joined(separator: "\n")
    }
}

extension ExtensionStatus: TextRenderable {
    var headline: String {
        let version = runningVersion.map { " \($0)" } ?? ""
        switch state {
        case .ready: return "Endpoint Extension\(version): ready"
        case .outdated: return "Endpoint Extension\(version): outdated (this MacFSW has \(bundledVersion ?? "a newer one"))"
        case .notInstalled: return "Endpoint Extension: not installed"
        case .needsFullDiskAccess: return "Endpoint Extension\(version): needs Full Disk Access"
        case .notAuthorized: return "Endpoint Extension\(version): not authorized"
        case .unreachable: return "Endpoint Extension: unavailable"
        }
    }

    var text: String {
        "\(headline)\n  \(message)"
    }
}

extension SessionInfo: TextRenderable {
    var text: String {
        let location = path.map { " (\($0))" } ?? ""
        return "Session: \(name)\(location) — \(events) events, \(captureState.rawValue), \(droppedEvents) dropped"
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
