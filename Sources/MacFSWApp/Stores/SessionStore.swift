import Foundation
import MacFSWCore

@MainActor
final class SessionStore: ObservableObject {
    @Published var session: MacFSWResearchSession
    var eventStore: MacFSWSQLiteEventStore

    private let makeTemporaryEventStore: (MacFSWResearchSession) throws -> MacFSWSQLiteEventStore

    init(environment: MacFSWAppEnvironment, initialSession: MacFSWResearchSession) {
        self.session = initialSession
        self.makeTemporaryEventStore = environment.makeTemporaryEventStore
        try? environment.cleanupStaleTemporaryStores()
        self.eventStore = try! environment.makeTemporaryEventStore(initialSession)
    }

    func makeTemporaryStore(for newSession: MacFSWResearchSession) throws -> MacFSWSQLiteEventStore {
        try makeTemporaryEventStore(newSession)
    }

    func replace(session newSession: MacFSWResearchSession, eventStore newStore: MacFSWSQLiteEventStore) -> MacFSWSQLiteEventStore {
        let oldStore = eventStore
        eventStore = newStore
        session = newSession
        return oldStore
    }

    func updateSession(_ update: (inout MacFSWResearchSession) -> Void) {
        var updated = session
        update(&updated)
        updated.metadata.updatedAt = Date()
        session = updated
    }

    func cleanupStoreIfOwned(_ store: MacFSWSQLiteEventStore) async throws {
        try await store.cleanupBackingStore()
    }
}
