import AppKit
import MacFSWAnalysis
import MacFSWCore
import SwiftUI
import XCTest
@testable import MacFSWApp

/// Renders the main window in representative states to PNG files for
/// visual review. Opt-in: `MACFSW_SNAPSHOT_DIR=/some/dir swift test
/// --filter UISnapshotTests`. Draws only this process's own window, so it
/// needs no screen-recording permission.
@MainActor
final class UISnapshotTests: XCTestCase {
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["MACFSW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set MACFSW_SNAPSHOT_DIR")
        }
        outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    func testEmptySession() async throws {
        let model = makeCoordinator()
        model.extensionStatus.applyHealth(MacFSWCaptureHealth(endpointSecurityAuthorized: true, message: "ok"))
        try await snapshot(model, named: "01-empty")
    }

    func testRecordedEventsWithInspector() async throws {
        let model = makeCoordinator()
        model.extensionStatus.applyHealth(MacFSWCaptureHealth(endpointSecurityAuthorized: true, message: "ok"))
        try await fill(model)
        model.monitor.selectEvent(nil, row: 3)
        try await settle()
        try await snapshot(model, named: "02-events-inspector")
    }

    /// The inspector column alone: offscreen rendering cannot draw it inside
    /// the window's split view.
    func testInspectorContent() async throws {
        let process = MacFSWProcessIdentity(pid: 1, auditToken: "a", executablePath: "/sbin/launchd", processName: "launchd", signingID: "com.apple.xpc.launchd", isPlatformBinary: true)
        let event = MacFSWFileEvent(eventType: .rename, process: process, targetPath: "/private/var/log/com.apple.xpc.launchd/launchd.log", sourcePath: "/private/var/log/com.apple.xpc.launchd/launchd.log.1")
        let host = NSHostingView(rootView: InspectorView(event: event, isLoading: false).frame(width: 380, height: 760))
        try await render(host, size: NSSize(width: 380, height: 760), named: "04-inspector")
    }

    func testExtensionNotInstalledWithError() async throws {
        let model = makeCoordinator()
        model.extensionStatus.applyHealthRefreshFailure(message: "unreachable")
        model.errorMessage = "XPC unavailable: The Endpoint Extension is not running or refused this connection. Open the MacFSW app to install it."
        try await snapshot(model, named: "03-extension-error")
    }

    // MARK: - Helpers

    private func makeCoordinator() -> MacFSWAppCoordinator {
        let defaults = UserDefaults(suiteName: "UISnapshotTests-\(UUID().uuidString)")!
        return MacFSWAppCoordinator(environment: MacFSWAppEnvironment(
            appVersion: "snapshot",
            captureClient: MacFSWXPCCaptureClient(serviceName: "invalid.macfsw.snapshot", healthTimeoutSeconds: 1),
            extensionInstaller: SnapshotInstaller(),
            settingsStore: MacFSWSettingsStore(defaults: defaults),
            llmClient: MacFSWLLMClient()
        ))
    }

    private func fill(_ model: MacFSWAppCoordinator) async throws {
        let processes = [
            MacFSWProcessIdentity(pid: 412, auditToken: "a", executablePath: "/System/Library/CoreServices/installd", processName: "installd", signingID: "com.apple.installd", isPlatformBinary: true),
            MacFSWProcessIdentity(pid: 977, auditToken: "b", executablePath: "/Applications/Example.app/Contents/MacOS/Example", processName: "Example", signingID: "com.example.app", teamID: "ABCDE12345"),
            MacFSWProcessIdentity(pid: 1203, auditToken: "c", executablePath: "/usr/bin/python3", processName: "python3", signingID: "com.apple.python3", isPlatformBinary: true),
        ]
        let paths = ["/Library/LaunchAgents/com.example.agent.plist", "/Users/me/Library/Caches/com.example/data.db", "/private/tmp/install.log", "/Applications/Example.app/Contents/Info.plist"]
        let types: [MacFSWEventType] = [.create, .write, .rename, .unlink, .chmod, .write]
        var events: [MacFSWFileEvent] = []
        for i in 0..<60 {
            events.append(MacFSWFileEvent(
                timestampNS: 1_760_000_000_000_000_000 + UInt64(i) * 37_000_000,
                eventType: types[i % types.count],
                process: processes[i % processes.count],
                targetPath: paths[i % paths.count],
                sourcePath: types[i % types.count] == .rename ? "/private/tmp/staging-\(i)" : nil
            ))
        }
        let result = try await model.session.eventStore.appendReturningEvents(events)
        model.ingest(result.events)
        await model.refreshProcessSummaries()
        await model.monitor.refreshFilteredEvents()
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    private func snapshot(_ model: MacFSWAppCoordinator, named name: String) async throws {
        let size = NSSize(width: 1440, height: 860)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: DashboardView().environment(model).frame(width: size.width, height: size.height))
        // Bridges the SwiftUI toolbar and title onto this window, as the
        // WindowGroup scene does in the app.
        host.sceneBridgingOptions = [.toolbars, .title]
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentView = host
        window.layoutIfNeeded()
        try await settle()
        // The frame view includes the title bar and toolbar.
        let frameView = try XCTUnwrap(host.superview)
        frameView.layoutSubtreeIfNeeded()
        let bounds = frameView.bounds
        guard let bitmap = frameView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return XCTFail("no bitmap")
        }
        frameView.cacheDisplay(in: bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
        window.close()
    }

    private func render(_ view: NSView, size: NSSize, named name: String) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        try await settle()
        try await settle()
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
        window.close()
    }
}

@MainActor
private final class SnapshotInstaller: SystemExtensionInstalling {
    var onStateChange: ((MacFSWSystemExtensionInstallState, String) -> Void)?
    var onUpdateStarted: ((String, String) -> Void)?
    func activate() {}
    func checkInstalledVersion() {}
    func openLoginItemsSettings() {}
    func openFullDiskAccessSettings() {}
}
