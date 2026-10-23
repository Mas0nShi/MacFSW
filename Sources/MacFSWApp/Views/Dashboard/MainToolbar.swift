import SwiftUI

/// The window toolbar: page switching in the middle, capture actions on
/// the trailing edge. These apply to the whole session, so they stay put
/// across pages.
struct MainToolbar: ToolbarContent {
    let model: MacFSWAppCoordinator
    let inspectorIsPresented: Binding<Bool>

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Page", selection: Binding(
                get: { model.selectedPage },
                set: { model.selectedPage = $0 }
            )) {
                ForEach(MacFSWNavigationPage.allCases) { page in
                    Text(page.isBeta ? "\(page.title) (Beta)" : page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if model.shouldShowJumpToLive {
                Button {
                    model.monitor.jumpToLive()
                } label: {
                    Label("Jump to Live", systemImage: "arrow.down.to.line")
                }
                .help("Scroll to the newest events and follow them")
            }

            Button {
                model.recordButtonTapped()
            } label: {
                Label(model.recordButtonTitle, systemImage: model.recordButtonSymbol)
            }
            .keyboardShortcut("r")
            .disabled(model.session.isReadOnly || model.session.captureState == .stopping)
            .help(model.session.isReadOnly ? Self.readOnlyHelp : "\(model.recordButtonTitle) (⌘R)")

            Button {
                model.clearView()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(model.session.isReadOnly || model.session.captureStats.deliveredEvents == 0)
            .help(model.session.isReadOnly ? Self.readOnlyHelp : "Delete every event in this session")

            if model.selectedPage == .monitor {
                Toggle(isOn: inspectorIsPresented) {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the event inspector (⌥⌘I)")
            }
        }
    }

    private static let readOnlyHelp = "Opened sessions are read-only. Start a new session (⌘N) to record."
}
