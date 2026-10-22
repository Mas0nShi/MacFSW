import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var coordinator: MacFSWAppCoordinator? {
        didSet { openPendingSessions() }
    }
    private var isTerminating = false
    /// Files opened from Finder or the Dock can arrive before the window
    /// and its coordinator exist, as when they launch the app.
    private var pendingSessionURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        pendingSessionURLs += urls
        openPendingSessions()
    }

    private func openPendingSessions() {
        // One session at a time: the last file opened wins.
        guard let coordinator, let url = pendingSessionURLs.last else {
            return
        }
        pendingSessionURLs.removeAll()
        coordinator.openSession(at: url)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            return .terminateNow
        }
        isTerminating = true
        Task { [weak self] in
            await self?.coordinator?.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
