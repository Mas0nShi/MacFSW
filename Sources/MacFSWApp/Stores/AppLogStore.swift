import AppKit
import Foundation

enum MacFSWAppLogLevel: String, CaseIterable, Identifiable {
    case error
    case info
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .error:
            "Errors"
        case .info:
            "Info"
        case .debug:
            "Debug"
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .error:
            0
        case .info:
            1
        case .debug:
            2
        }
    }
}

actor MacFSWLogWriter {
    func append(_ entry: String, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(entry.utf8))
    }

    func clear(_ fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: fileURL, options: .atomic)
    }
}

@MainActor
final class AppLogStore: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.isEnabledKey)
        }
    }

    @Published var minimumLevel: MacFSWAppLogLevel {
        didSet {
            defaults.set(minimumLevel.rawValue, forKey: Self.minimumLevelKey)
        }
    }

    @Published private(set) var lastWriteError: String?

    let logDirectoryURL: URL
    let logFileURL: URL

    private let defaults: UserDefaults
    private let writer = MacFSWLogWriter()
    private static let isEnabledKey = "MacFSW.Diagnostics.Logs.Enabled"
    private static let minimumLevelKey = "MacFSW.Diagnostics.Logs.MinimumLevel"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Self.isEnabledKey) as? Bool ?? true
        let rawLevel = defaults.string(forKey: Self.minimumLevelKey)
        self.minimumLevel = rawLevel.flatMap(MacFSWAppLogLevel.init(rawValue:)) ?? .info
        self.logDirectoryURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacFSW", isDirectory: true)
        self.logFileURL = logDirectoryURL.appendingPathComponent("MacFSW.log")
    }

    func record(
        _ level: MacFSWAppLogLevel,
        _ message: String,
        category: String,
        error: Error? = nil,
        metadata: [String: String] = [:]
    ) {
        guard isEnabled, level.priority <= minimumLevel.priority else {
            return
        }

        let entry = makeEntry(
            level: level,
            category: category,
            message: message,
            error: error,
            metadata: metadata
        )
        let fileURL = logFileURL
        Task { [writer] in
            do {
                try await writer.append(entry, to: fileURL)
            } catch {
                await MainActor.run {
                    self.lastWriteError = ErrorPresentation.userFacingMessage(error)
                }
            }
        }
    }

    func openLogsFolder() {
        do {
            try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                try Data().write(to: logFileURL, options: .atomic)
            }
            NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
        } catch {
            lastWriteError = ErrorPresentation.userFacingMessage(error)
        }
    }

    func copyLogFilePath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logFileURL.path, forType: .string)
    }

    func clearLog() {
        let fileURL = logFileURL
        Task { [writer] in
            do {
                try await writer.clear(fileURL)
                await MainActor.run {
                    self.lastWriteError = nil
                }
            } catch {
                await MainActor.run {
                    self.lastWriteError = ErrorPresentation.userFacingMessage(error)
                }
            }
        }
    }

    private func makeEntry(
        level: MacFSWAppLogLevel,
        category: String,
        message: String,
        error: Error?,
        metadata: [String: String]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parts = [
            formatter.string(from: Date()),
            "[\(level.rawValue.uppercased())]",
            "[\(category)]",
            sanitize(message),
        ]
        if let error {
            parts.append("error=\(sanitize(String(reflecting: error)))")
        }
        for key in metadata.keys.sorted() {
            if let value = metadata[key] {
                parts.append("\(key)=\(sanitize(value))")
            }
        }
        return parts.joined(separator: " ") + "\n"
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
