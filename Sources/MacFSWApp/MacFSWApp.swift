import AppKit
import SwiftUI

@main
struct MacFSWApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = MacFSWAppCoordinator()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(coordinator)
                .frame(minWidth: 1180, minHeight: 720)
                .onAppear {
                    appDelegate.coordinator = coordinator
                }
                .task {
                    await coordinator.refreshHealth()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    coordinator.newSession()
                }
                .keyboardShortcut("n")

                Button("Open Session...") {
                    coordinator.openSession()
                }
                .keyboardShortcut("o")

                Divider()

                Button("Save Session...") {
                    coordinator.saveSession()
                }
                .keyboardShortcut("s")
            }

            CommandGroup(replacing: .windowArrangement) {}

            CommandGroup(replacing: .help) {
                Button("MacFSW User Manual") {
                    NSWorkspace.shared.open(MacFSWExternalLinks.userManual)
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(coordinator)
                .frame(width: 760, height: 540)
        }
    }
}
