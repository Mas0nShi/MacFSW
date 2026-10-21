import ArgumentParser
import Foundation
import MacFSWCommands
import MacFSWCore

extension MacFSWCaptureProfile: ExpressibleByArgument {}

struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record file-system activity into a .macfsw-session file.",
        discussion: "Recording stops after --duration seconds or on Ctrl-C, then the session is saved."
    )

    @Option(name: [.short, .long], help: "Where to save the session.", completion: .file(extensions: [MacFSWSessionArchive.nativeExtension]))
    var out: String
    @Option(help: "Seconds to record.")
    var duration = 30
    @Option(help: "Event set to subscribe to.")
    var profile = MacFSWCaptureProfile.focusedMutations
    @Option(name: .customLong("pid"), help: "Only record these process IDs.")
    var pids: [Int32] = []
    @Option(name: .customLong("process"), help: "Only record processes with these names.")
    var processes: [String] = []
    @Option(name: .customLong("include-path"), help: "Only record events under these path prefixes.")
    var includePaths: [String] = []
    @Option(name: .customLong("exclude-path"), help: "Skip events under these path prefixes.")
    var excludePaths: [String] = []
    @Option(name: .customLong("exclude-process"), help: "Skip processes whose names contain these strings.")
    var excludeProcesses: [String] = []
    @Flag(help: "Replace --out if it already exists.")
    var force = false
    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard duration > 0 else {
            throw ValidationError("--duration must be at least 1 second.")
        }
        guard force || !FileManager.default.fileExists(atPath: out) else {
            throw ValidationError("\(out) already exists; pass --force to replace it.")
        }
    }

    func run() async throws {
        var request = CaptureRequest()
        request.profile = profile
        request.durationSeconds = duration
        request.targetPIDs = pids
        request.targetProcessNames = processes
        request.includePaths = includePaths
        request.excludePaths = excludePaths
        request.excludeProcessNames = excludeProcesses

        let workspace = MacFSWCommand.makeWorkspace()
        let interrupt = Interrupt()
        _ = try await workspace.startCapture(request)
        Self.log("Recording for up to \(duration)s; press Ctrl-C to stop early.")

        while try await workspace.sessionInfo().captureState == .recording, !interrupt.received {
            try await Task.sleep(for: .milliseconds(200))
        }
        let stopped = try await workspace.stopCapture()
        if stopped.captureState == .failed {
            Self.log("Capture ended with an error; saving what was recorded.")
        }
        let saved = try await workspace.save(to: URL(fileURLWithPath: out), overwrite: force)
        try await workspace.close()
        try Output.print(saved, json: output.json)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Turns the first Ctrl-C into a flag so recording can stop cleanly and
/// still save; a second Ctrl-C terminates as usual.
private final class Interrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private let source: DispatchSourceSignal

    init() {
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signal(SIGINT, SIG_IGN)
        source.setEventHandler { [unowned self] in
            lock.withLock { flag = true }
            source.cancel()
            signal(SIGINT, SIG_DFL)
        }
        source.resume()
    }

    var received: Bool {
        lock.withLock { flag }
    }
}
