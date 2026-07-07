import Foundation

@MainActor
final class QueryHistoryStore: ObservableObject {
    @Published private(set) var entries: [String] = []

    private let defaults: UserDefaults
    private static let entriesKey = "MacFSW.QueryHistory.v1"
    private static let maxEntries = 10

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.entriesKey),
           let stored = try? JSONDecoder().decode([String].self, from: data) {
            entries = stored
        }
    }

    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        var updated = entries.filter { $0 != trimmed }
        updated.insert(trimmed, at: 0)
        entries = Array(updated.prefix(Self.maxEntries))
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else {
            return
        }
        defaults.set(data, forKey: Self.entriesKey)
    }
}
