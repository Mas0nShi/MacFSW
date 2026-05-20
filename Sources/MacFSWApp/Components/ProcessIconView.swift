import AppKit
import SwiftUI

struct ProcessIconView: View {
    let executablePath: String
    let fallbackSymbolName: String

    init(executablePath: String, fallbackSymbolName: String) {
        self.executablePath = executablePath
        self.fallbackSymbolName = fallbackSymbolName
    }

    init(summary: MacFSWProcessSummary) {
        self.executablePath = summary.executablePath
        self.fallbackSymbolName = summary.processIconSymbolName
    }

    init(group: MacFSWProcessGroupSummary) {
        self.executablePath = group.representativeSummary?.executablePath ?? ""
        self.fallbackSymbolName = group.processIconSymbolName
    }

    var body: some View {
        Group {
            if let icon = ProcessIconCache.shared.icon(forExecutablePath: executablePath) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

@MainActor
private final class ProcessIconCache {
    static let shared = ProcessIconCache()

    private var cache: [String: NSImage] = [:]

    func icon(forExecutablePath executablePath: String) -> NSImage? {
        guard let appBundlePath = MacFSWProcessSummary.appBundlePath(for: executablePath) else {
            return nil
        }
        if let cached = cache[appBundlePath] {
            return cached
        }

        let icon = NSWorkspace.shared.icon(forFile: appBundlePath)
        icon.size = NSSize(width: 18, height: 18)
        cache[appBundlePath] = icon
        return icon
    }
}
