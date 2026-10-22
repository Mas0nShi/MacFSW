import AppKit
import SwiftUI

@main
struct MacFSWApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = MacFSWAppCoordinator()
    @AppStorage("MacFSW.ShowsInspector") private var showsInspector = true

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environment(coordinator)
                .frame(minWidth: 1180, minHeight: 720)
                .onAppear {
                    appDelegate.coordinator = coordinator
                }
                .task {
                    await coordinator.refreshHealth()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .sidebar) {
                Button(showsInspector ? "Hide Inspector" : "Show Inspector") {
                    showsInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
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
                .environment(coordinator)
                .frame(width: 760, height: 540)
        }
    }
}
