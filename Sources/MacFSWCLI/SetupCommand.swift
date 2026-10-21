import ArgumentParser
import Foundation
import MacFSWCommands
import MacFSWCore

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Install or update the Endpoint Extension and wait until recording works.",
        discussion: """
        macOS only accepts extension installs from the MacFSW app, so this opens \
        the app, asks it to install or update the extension, and reports progress \
        here until the extension is ready. Approve the extension if macOS asks.
        """
    )

    @Option(help: "Seconds to wait before giving up.")
    var timeout = 180

    func run() async throws {
        let client = MacFSWCommand.makeClient()
        let inspector = MacFSWCommand.makeInspector()

        var status = await inspector.inspect(client)
        guard status.state != .ready else {
            print(status.headline)
            return
        }
        print(status.text)

        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            throw ValidationError("Run the macfsw inside MacFSW.app (\(appURL.path) is not an app bundle).")
        }
        print("Opening MacFSW to install or update the Endpoint Extension…")
        try Self.requestSetup(from: appURL)

        var lastHeadline = status.headline
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            status = await inspector.inspect(client)
            if status.state == .ready {
                print(status.headline)
                return
            }
            if status.headline != lastHeadline {
                lastHeadline = status.headline
                print(status.headline)
                print("  \(Self.guidance(for: status))")
            }
        }
        print("Gave up after \(timeout)s. \(status.message)")
        throw ExitCode.failure
    }

    /// Launches the app with the setup argument; an app that is already
    /// running ignores launch arguments, so it is also notified directly.
    private static func requestSetup(from appURL: URL) throws {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", appURL.path, "--args", MacFSWExtensionSetupSignal.launchArgument]
        try open.run()
        open.waitUntilExit()
        DistributedNotificationCenter.default().postNotificationName(
            MacFSWExtensionSetupSignal.notification,
            object: nil,
            deliverImmediately: true
        )
    }

    private static func guidance(for status: ExtensionStatus) -> String {
        switch status.state {
        case .needsFullDiskAccess:
            "Grant Full Disk Access to MacFSW Endpoint Extension in System Settings > Privacy & Security."
        case .outdated, .notInstalled, .unreachable:
            "Waiting for macOS to activate the extension. If asked, approve it in System Settings > General > Login Items & Extensions."
        case .notAuthorized, .ready:
            status.message
        }
    }
}

/// Reads `systemextensionsctl list`, the only way to see the activated
/// extension's version when that extension refuses our connection.
enum SystemExtensionsList {
    static func activatedVersion(of identifier: String) -> MacFSWComponentVersion? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        process.arguments = ["list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseActivatedVersion(of: identifier, in: String(decoding: data, as: UTF8.self))
    }

    /// Matches lines like
    /// `*  *  TEAMID  com.example.ext (1.2.3/45)  Name  [activated enabled]`.
    static func parseActivatedVersion(of identifier: String, in listing: String) -> MacFSWComponentVersion? {
        for line in listing.split(separator: "\n") where line.contains("\(identifier) (") && line.contains("[activated enabled]") {
            guard let open = line.range(of: "\(identifier) ("),
                  let close = line[open.upperBound...].firstIndex(of: ")") else {
                continue
            }
            let parts = line[open.upperBound..<close].split(separator: "/", maxSplits: 1)
            if parts.count == 2 {
                return MacFSWComponentVersion(shortVersion: String(parts[0]), build: String(parts[1]))
            }
        }
        return nil
    }
}
