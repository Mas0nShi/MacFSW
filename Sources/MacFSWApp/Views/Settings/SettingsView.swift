import SwiftUI

enum MacFSWSettingsSection: String, CaseIterable, Identifiable {
    case general
    case analysis
    case capture
    case systemExtension
    case agents
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            "General"
        case .analysis:
            "Analysis"
        case .capture:
            "Capture"
        case .systemExtension:
            "System Extension"
        case .agents:
            "CLI & Agents"
        case .logs:
            "Logs"
        }
    }

    var symbolName: String {
        switch self {
        case .general:
            "gearshape"
        case .analysis:
            "sparkles.rectangle.stack"
        case .capture:
            "record.circle"
        case .systemExtension:
            "puzzlepiece.extension"
        case .agents:
            "terminal"
        case .logs:
            "doc.text.magnifyingglass"
        }
    }

    var isBeta: Bool {
        switch self {
        case .analysis:
            true
        case .general, .capture, .systemExtension, .agents, .logs:
            false
        }
    }
}

struct SettingsView: View {
    @State private var selection: MacFSWSettingsSection = .analysis

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(MacFSWSettingsSection.allCases) { section in
                    HStack(spacing: 6) {
                        Label(section.title, systemImage: section.symbolName)
                        if section.isBeta {
                            MacFSWBetaBadge()
                        }
                    }
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            Group {
                switch selection {
                case .general:
                    GeneralSettingsPane()
                case .analysis:
                    AnalysisSettingsPane()
                case .capture:
                    CaptureSettingsPane()
                case .systemExtension:
                    SystemExtensionSettingsPane()
                case .agents:
                    AgentSettingsPane()
                case .logs:
                    LogsSettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
