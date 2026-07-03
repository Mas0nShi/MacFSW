import XCTest
@testable import MacFSWCore

final class MacFSWCoreTests: XCTestCase {
    func testQueryParserBuildsStructuredFilters() {
        let query = MacFSWQueryParser.parse("process:cfprefsd op:write path:/Library apple:false")

        XCTAssertEqual(query.text, "process:cfprefsd op:write path:/Library apple:false")
        XCTAssertNotNil(query.expression)
    }

    func testTeamFilterMatchesTeamIdentifierOnly() {
        let exactQuery = MacFSWQueryParser.parse("team:ABCDE12345")
        let wildcardQuery = MacFSWQueryParser.parse("team:ABC*")

        let matchingProcess = MacFSWProcessIdentity(
            pid: 3,
            auditToken: "third-party",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            processName: "Example",
            signingID: "com.example.app",
            teamID: "ABCDE12345",
            isPlatformBinary: false
        )
        let appleProcess = MacFSWProcessIdentity(
            pid: 4,
            auditToken: "apple",
            executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            processName: "Finder",
            signingID: "com.apple.finder",
            teamID: nil,
            isPlatformBinary: true
        )

        XCTAssertTrue(exactQuery.matches(MacFSWFileEvent(eventType: .write, process: matchingProcess, targetPath: "/tmp/a")))
        XCTAssertTrue(wildcardQuery.matches(MacFSWFileEvent(eventType: .write, process: matchingProcess, targetPath: "/tmp/b")))
        XCTAssertFalse(exactQuery.matches(MacFSWFileEvent(eventType: .write, process: appleProcess, targetPath: "/tmp/c")))
    }

    func testAdvancedQueryHonorsOrNotAndParentheses() {
        let query = MacFSWQueryParser.parse("(op:rename OR op:unlink) path:/Library NOT platform:true")
        let thirdPartyProcess = MacFSWProcessIdentity(
            pid: 11,
            auditToken: "third-party",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            processName: "Example",
            signingID: "com.example.app",
            teamID: "ABCDE12345",
            isPlatformBinary: false
        )
        let platformProcess = MacFSWProcessIdentity(
            pid: 12,
            auditToken: "platform",
            executablePath: "/usr/libexec/xpcproxy",
            processName: "xpcproxy",
            isPlatformBinary: true
        )

        XCTAssertTrue(query.matches(MacFSWFileEvent(eventType: .rename, process: thirdPartyProcess, targetPath: "/Library/a")))
        XCTAssertTrue(query.matches(MacFSWFileEvent(eventType: .unlink, process: thirdPartyProcess, targetPath: "/Library/b")))
        XCTAssertFalse(query.matches(MacFSWFileEvent(eventType: .write, process: thirdPartyProcess, targetPath: "/Library/c")))
        XCTAssertFalse(query.matches(MacFSWFileEvent(eventType: .rename, process: platformProcess, targetPath: "/Library/d")))
    }

    func testAppleFilterMatchesPlatformAndAppleSigningIdentity() {
        let appleQuery = MacFSWQueryParser.parse("apple:true")
        let thirdPartyQuery = MacFSWQueryParser.parse("apple:false")

        let platformProcess = MacFSWProcessIdentity(
            pid: 1,
            auditToken: "platform",
            executablePath: "/usr/libexec/xpcproxy",
            processName: "xpcproxy",
            signingID: nil,
            teamID: nil,
            isPlatformBinary: true
        )
        let appleSignedProcess = MacFSWProcessIdentity(
            pid: 2,
            auditToken: "apple",
            executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            processName: "Safari",
            signingID: "com.apple.Safari",
            teamID: nil,
            isPlatformBinary: false
        )
        let thirdPartyProcess = MacFSWProcessIdentity(
            pid: 3,
            auditToken: "third-party",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            processName: "Example",
            signingID: "com.example.app",
            teamID: "ABCDE12345",
            isPlatformBinary: false
        )

        XCTAssertTrue(appleQuery.matches(MacFSWFileEvent(eventType: .write, process: platformProcess, targetPath: "/tmp/a")))
        XCTAssertTrue(appleQuery.matches(MacFSWFileEvent(eventType: .write, process: appleSignedProcess, targetPath: "/tmp/b")))
        XCTAssertFalse(appleQuery.matches(MacFSWFileEvent(eventType: .write, process: thirdPartyProcess, targetPath: "/tmp/c")))
        XCTAssertTrue(thirdPartyQuery.matches(MacFSWFileEvent(eventType: .write, process: thirdPartyProcess, targetPath: "/tmp/d")))
    }

    func testInMemoryStoreFiltersEvents() async {
        let store = MacFSWInMemoryEventStore(maxEvents: 10_000)
        let process = MacFSWProcessIdentity(
            pid: 42,
            auditToken: "test",
            executablePath: "/usr/libexec/tester",
            processName: "tester"
        )
        let event = MacFSWFileEvent(
            eventType: .write,
            process: process,
            targetPath: "/Library/LaunchAgents/com.example.agent.plist",
            uid: 501,
            gid: 20
        )

        _ = await store.append([event])
        let results = await store.query(MacFSWQueryParser.parse("process:tester path:LaunchAgents"))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.eventType, .write)
    }

    func testSQLiteSessionArchiveRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macfsw-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let process = MacFSWProcessIdentity(
            pid: 7,
            auditToken: "archive",
            executablePath: "/bin/sh",
            processName: "sh"
        )
        let session = MacFSWResearchSession(name: "Archive Test")
        let store = try MacFSWSQLiteEventStore.temporary(session: session)
        let appended = try await store.appendReturningEvents([
            MacFSWFileEvent(eventType: .rename, process: process, targetPath: "/tmp/a", sourcePath: "/tmp/b")
        ])

        XCTAssertEqual(appended.events.first?.sequence, 1)

        let sessionURL = directory.appendingPathComponent("Archive Test.macfsw-session")
        try await MacFSWSessionArchive.saveSession(session, from: store, to: sessionURL)
        let openedStore = try MacFSWSessionArchive.openSessionStore(from: sessionURL)
        let opened = try await openedStore.sessionMetadata()

        XCTAssertEqual(opened.name, "Archive Test")
        let openedCount = try await openedStore.count(matching: MacFSWEventQuery())
        XCTAssertEqual(openedCount, 1)

    }

    func testTemporarySQLiteStoreCleansUpBackingDirectory() async throws {
        let store = try MacFSWSQLiteEventStore.temporary()
        let directory = store.url.deletingLastPathComponent()

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        try await store.cleanupBackingStore()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSQLiteConcurrentStoreInstancesAssignDatabaseBackedSequences() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macfsw-concurrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("session.sqlite")
        let storeA = try MacFSWSQLiteEventStore(url: url)
        let storeB = try MacFSWSQLiteEventStore(url: url)
        let process = MacFSWProcessIdentity(
            pid: 71,
            auditToken: "concurrent",
            executablePath: "/usr/bin/tester",
            processName: "tester"
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for batch in 0..<10 {
                group.addTask {
                    let store = batch.isMultiple(of: 2) ? storeA : storeB
                    let events = (0..<10).map { index in
                        MacFSWFileEvent(
                            eventType: .write,
                            process: process,
                            targetPath: "/tmp/concurrent-\(batch)-\(index)"
                        )
                    }
                    _ = try await store.appendReturningEvents(events)
                }
            }
            try await group.waitForAll()
        }

        let events = try await storeA.snapshot()
        let sequences = events.map(\.sequence).sorted()

        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(Set(sequences).count, 100)
        XCTAssertEqual(sequences, (1...100).map(UInt64.init))
    }

    func testSQLiteStoreFiltersAndPagesRows() async throws {
        let process = MacFSWProcessIdentity(
            pid: 99,
            auditToken: "sqlite",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            processName: "Example",
            signingID: "com.example.app",
            teamID: "ABCDE12345"
        )
        let store = try MacFSWSQLiteEventStore.temporary()
        _ = try await store.appendReturningEvents([
            MacFSWFileEvent(eventType: .write, process: process, targetPath: "/tmp/a"),
            MacFSWFileEvent(eventType: .unlink, process: process, targetPath: "/Library/LaunchAgents/a.plist"),
            MacFSWFileEvent(eventType: .rename, process: process, targetPath: "/tmp/c", sourcePath: "/tmp/b"),
        ])

        let query = MacFSWQueryParser.parse("(op:unlink OR op:rename) process:Example")
        let rows = try await store.rowSummaries(matching: query, visibleRange: 0..<10, sortOrder: .oldestFirst)

        let count = try await store.count(matching: query)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(rows.map(\.eventType), [.unlink, .rename])
        XCTAssertEqual(rows.first?.sequence, 2)

        let selected = try await store.event(matching: query, visibleRow: 1, sortOrder: .oldestFirst)
        XCTAssertEqual(selected?.eventType, .rename)
        XCTAssertEqual(selected?.sequence, 3)
    }

    func testSQLiteOperationParametersRoundTripAndSearch() async throws {
        let process = MacFSWProcessIdentity(
            pid: 100,
            auditToken: "params",
            executablePath: "/usr/bin/chmod",
            processName: "chmod"
        )
        let store = try MacFSWSQLiteEventStore.temporary()
        _ = try await store.appendReturningEvents([
            MacFSWFileEvent(
                eventType: .chmod,
                process: process,
                targetPath: "/tmp/target",
                parameters: [
                    MacFSWEventParameter(key: "mode", label: "Mode", value: "0644"),
                    MacFSWEventParameter(key: "current_mode", label: "Current Mode", value: "0755"),
                ]
            )
        ])

        let rows = try await store.rowSummaries(
            matching: MacFSWEventQuery(),
            visibleRange: 0..<10,
            sortOrder: .oldestFirst
        )
        let selected = try await store.event(matching: MacFSWQueryParser.parse("detail:0644"), visibleRow: 0)
        let count = try await store.count(matching: MacFSWQueryParser.parse("0644"))

        XCTAssertEqual(rows.first?.detailSummary, "mode 0644 · was 0755")
        XCTAssertEqual(selected?.parameters.first?.value, "0644")
        XCTAssertEqual(count, 1)
    }

    func testSQLiteRawEventTypeValueRoundTripsAndSearches() async throws {
        let process = MacFSWProcessIdentity(
            pid: 102,
            auditToken: "raw-type",
            executablePath: "/usr/bin/touch",
            processName: "touch"
        )
        let store = try MacFSWSQLiteEventStore.temporary()
        _ = try await store.appendReturningEvents([
            MacFSWFileEvent(
                eventType: .write,
                process: process,
                targetPath: "/tmp/raw-value",
                rawEventType: "ES_EVENT_TYPE_NOTIFY_WRITE",
                rawEventTypeValue: 987_654
            ),
            MacFSWFileEvent(
                eventType: .unlink,
                process: process,
                targetPath: "/tmp/no-raw-value",
                rawEventType: "ES_EVENT_TYPE_NOTIFY_UNLINK"
            ),
        ])

        let selected = try await store.event(
            matching: MacFSWQueryParser.parse("rawtype:987654"),
            visibleRow: 0,
            sortOrder: .oldestFirst
        )
        let rawValueCount = try await store.count(matching: MacFSWQueryParser.parse("rawtype:987654"))
        let genericCount = try await store.count(matching: MacFSWQueryParser.parse("987654"))

        XCTAssertEqual(selected?.rawEventTypeValue, 987_654)
        XCTAssertEqual(rawValueCount, 1)
        XCTAssertEqual(genericCount, 1)
    }

    func testSQLiteOperationSummariesHonorQuery() async throws {
        let process = MacFSWProcessIdentity(
            pid: 101,
            auditToken: "ops",
            executablePath: "/Applications/Ops.app/Contents/MacOS/Ops",
            processName: "Ops"
        )
        let store = try MacFSWSQLiteEventStore.temporary()
        _ = try await store.appendReturningEvents([
            MacFSWFileEvent(eventType: .write, process: process, targetPath: "/tmp/a"),
            MacFSWFileEvent(eventType: .write, process: process, targetPath: "/tmp/b"),
            MacFSWFileEvent(eventType: .rename, process: process, targetPath: "/tmp/c", sourcePath: "/tmp/d"),
            MacFSWFileEvent(eventType: .unlink, process: process, targetPath: "/private/x"),
        ])

        let query = MacFSWQueryParser.parse("path:/tmp")
        let summaries = try await store.operationSummaries(matching: query)
        let counts = Dictionary(uniqueKeysWithValues: summaries.map { ($0.eventType, $0.eventCount) })

        XCTAssertEqual(counts[.write], 2)
        XCTAssertEqual(counts[.rename], 1)
        XCTAssertNil(counts[.unlink])
    }

    func testProcessIdentityQueryCompilesToPIDOnlySQL() {
        let auditQuery = MacFSWEventQuery(
            processIdentity: MacFSWProcessFilterIdentity(
                pid: 42,
                auditToken: "token-a",
                executablePath: "/Applications/A.app/Contents/MacOS/A"
            )
        )
        let auditSQL = MacFSWSQLQueryCompiler.compile(auditQuery).whereSQL

        XCTAssertTrue(auditSQL.contains("pid = ?"))
        XCTAssertFalse(auditSQL.contains("auditToken = ?"))
        XCTAssertFalse(auditSQL.contains("lower(coalesce(auditToken"))

        let executableQuery = MacFSWEventQuery(
            processIdentity: MacFSWProcessFilterIdentity(
                pid: 42,
                auditToken: "",
                executablePath: "/Applications/A.app/Contents/MacOS/A"
            )
        )
        let executableSQL = MacFSWSQLQueryCompiler.compile(executableQuery).whereSQL

        XCTAssertTrue(executableSQL.contains("pid = ?"))
        XCTAssertFalse(executableSQL.contains("executablePath = ?"))
    }

    func testEnumQueryCompilesToIndexedEquality() {
        let operationClassSQL = MacFSWSQLQueryCompiler
            .compile(MacFSWQueryParser.parse("opclass:write"))
            .whereSQL
        let eventTypeSQL = MacFSWSQLQueryCompiler
            .compile(MacFSWQueryParser.parse("op:rename"))
            .whereSQL

        XCTAssertTrue(operationClassSQL.contains("operationClass = ?"))
        XCTAssertFalse(operationClassSQL.contains("lower(operationClass)"))
        XCTAssertTrue(eventTypeSQL.contains("eventType = ?"))
        XCTAssertFalse(eventTypeSQL.contains("lower(eventType)"))
    }

    func testIndexedTextQueryUsesFTSWithoutLikeFallback() {
        let pathSQL = MacFSWSQLQueryCompiler
            .compile(MacFSWQueryParser.parse("path:/Library"))
            .whereSQL
        let parameterSQL = MacFSWSQLQueryCompiler
            .compile(MacFSWQueryParser.parse("detail:0644"))
            .whereSQL

        XCTAssertTrue(pathSQL.contains("event_fts"))
        XCTAssertTrue(pathSQL.contains("MATCH"))
        XCTAssertFalse(pathSQL.contains("LIKE"))
        XCTAssertTrue(parameterSQL.contains("LIKE"))
    }

    func testSQLiteProcessIdentityFilterUsesPIDAcrossAuditTokens() async throws {
        let reusedPID: Int32 = 4242
        let firstProcess = MacFSWProcessIdentity(
            pid: reusedPID,
            auditToken: "first-token",
            executablePath: "/Applications/First.app/Contents/MacOS/First",
            processName: "First"
        )
        let secondProcess = MacFSWProcessIdentity(
            pid: reusedPID,
            auditToken: "second-token",
            executablePath: "/Applications/Second.app/Contents/MacOS/Second",
            processName: "Second"
        )
        let store = try MacFSWSQLiteEventStore.temporary()
        _ = try await store.appendReturningEvents([
            MacFSWFileEvent(eventType: .write, process: firstProcess, targetPath: "/tmp/first"),
            MacFSWFileEvent(eventType: .write, process: secondProcess, targetPath: "/tmp/second"),
        ])

        let query = MacFSWEventQuery(processIdentity: firstProcess.filterIdentity)
        let rows = try await store.rowSummaries(matching: query, visibleRange: 0..<10, sortOrder: .oldestFirst)
        let count = try await store.count(matching: query)

        XCTAssertEqual(count, 2)
        XCTAssertEqual(rows.map(\.targetPath), ["/tmp/first", "/tmp/second"])
    }

    func testSQLiteProcessIdentityFilterUsesPIDAcrossExecutablesWhenAuditTokenIsMissing() async throws {
        let reusedPID: Int32 = 5252
        let firstProcess = MacFSWProcessIdentity(
            pid: reusedPID,
            auditToken: "",
            executablePath: "/tmp/first-tool",
            processName: "tool"
        )
        let secondProcess = MacFSWProcessIdentity(
            pid: reusedPID,
            auditToken: "",
            executablePath: "/tmp/second-tool",
            processName: "tool"
        )
        let store = try MacFSWSQLiteEventStore.temporary()
        _ = try await store.appendReturningEvents([
            MacFSWFileEvent(eventType: .write, process: firstProcess, targetPath: "/tmp/first"),
            MacFSWFileEvent(eventType: .write, process: secondProcess, targetPath: "/tmp/second"),
        ])

        let query = MacFSWEventQuery(processIdentity: secondProcess.filterIdentity)
        let rows = try await store.rowSummaries(matching: query, visibleRange: 0..<10, sortOrder: .oldestFirst)
        let count = try await store.count(matching: query)

        XCTAssertEqual(count, 2)
        XCTAssertEqual(rows.map(\.targetPath), ["/tmp/first", "/tmp/second"])
    }

    func testSQLiteResultSnapshotPagesVirtualSnapshot() async throws {
        let process = MacFSWProcessIdentity(
            pid: 88,
            auditToken: "snapshot",
            executablePath: "/tmp/snapshot",
            processName: "snapshot"
        )
        let store = try MacFSWSQLiteEventStore.temporary()
        _ = try await store.appendReturningEvents((0..<8).map { index in
            MacFSWFileEvent(eventType: .write, process: process, targetPath: "/tmp/\(index)")
        })

        let snapshot = try await store.createResultSnapshot(
            matching: MacFSWEventQuery(processIdentity: process.filterIdentity, limit: 5),
            sortOrder: .oldestFirst
        )
        let rows = try await store.rowSummaries(in: snapshot, visibleRange: 0..<5)
        let selected = try await store.event(in: snapshot, visibleRow: 4)
        let selectedIndex = try await store.visibleRowIndex(of: rows[2].id, in: snapshot)

        XCTAssertEqual(snapshot.totalCount, 8)
        XCTAssertEqual(snapshot.visibleCount, 5)
        XCTAssertEqual(rows.map(\.targetPath), ["/tmp/3", "/tmp/4", "/tmp/5", "/tmp/6", "/tmp/7"])
        XCTAssertEqual(selected?.targetPath, "/tmp/7")
        XCTAssertEqual(selectedIndex, 2)
    }

    func testSQLiteDefaultQueryAndSnapshotAreUnlimited() async throws {
        let process = MacFSWProcessIdentity(
            pid: 90,
            auditToken: "unlimited",
            executablePath: "/tmp/unlimited",
            processName: "unlimited"
        )
        let store = try MacFSWSQLiteEventStore.temporary()
        _ = try await store.appendReturningEvents((0..<8).map { index in
            MacFSWFileEvent(eventType: .write, process: process, targetPath: "/tmp/\(index)")
        })

        let query = MacFSWEventQuery(processIdentity: process.filterIdentity)
        let snapshot = try await store.createResultSnapshot(matching: query, sortOrder: .oldestFirst)
        let rows = try await store.rowSummaries(in: snapshot, visibleRange: 0..<20)
        let count = try await store.count(matching: query)

        XCTAssertFalse(query.hasVisibleLimit)
        XCTAssertEqual(count, 8)
        XCTAssertEqual(snapshot.totalCount, 8)
        XCTAssertEqual(snapshot.visibleCount, 8)
        XCTAssertEqual(rows.map(\.targetPath), (0..<8).map { "/tmp/\($0)" })

        let appendResult = try await store.appendReturningEvents([
            MacFSWFileEvent(eventType: .rename, process: process, targetPath: "/tmp/8")
        ])
        let updatedSnapshot = try await store.appendRowsToResultSnapshot(
            snapshot,
            rows: appendResult.events.map(MacFSWEventRowSummary.init(event:)),
            limit: query.limit
        )
        let appendedRows = try await store.rowSummaries(in: updatedSnapshot, visibleRange: 8..<9)

        XCTAssertEqual(updatedSnapshot.totalCount, 9)
        XCTAssertEqual(updatedSnapshot.visibleCount, 9)
        XCTAssertEqual(appendedRows.map(\.targetPath), ["/tmp/8"])
    }

    func testSQLiteEventsFetchesRecentProcessEventsWithoutSnapshot() async throws {
        let process = MacFSWProcessIdentity(
            pid: 91,
            auditToken: "analysis",
            executablePath: "/tmp/analysis",
            processName: "analysis"
        )
        let otherProcess = MacFSWProcessIdentity(
            pid: 92,
            auditToken: "other",
            executablePath: "/tmp/other",
            processName: "other"
        )
        let store = try MacFSWSQLiteEventStore.temporary()
        _ = try await store.appendReturningEvents((0..<6).map { index in
            MacFSWFileEvent(eventType: .write, process: process, targetPath: "/tmp/analysis-\(index)")
        } + [
            MacFSWFileEvent(eventType: .unlink, process: otherProcess, targetPath: "/tmp/other")
        ])

        let newest = try await store.events(
            matching: MacFSWEventQuery(processIdentity: process.filterIdentity),
            sortOrder: .newestFirst,
            limit: 3
        )

        XCTAssertEqual(newest.map(\.targetPath), ["/tmp/analysis-5", "/tmp/analysis-4", "/tmp/analysis-3"])
    }

    func testOpeningNonSQLiteArchiveReportsUnsupportedFormat() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macfsw-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("legacy.macfsw-session")
        try Data("{\"events\":[]}".utf8).write(to: url)

        XCTAssertThrowsError(try MacFSWSessionArchive.openSessionStore(from: url)) { error in
            XCTAssertTrue(error is MacFSWArchiveError)
        }
    }

    func testFieldCatalogCoversEveryQueryField() {
        let coveredFields = MacFSWQueryFieldCatalog.descriptors.map(\.field)
        XCTAssertEqual(Set(coveredFields), Set(MacFSWQueryField.allCases))
        XCTAssertEqual(coveredFields.count, MacFSWQueryField.allCases.count)

        var seenAliases: Set<String> = []
        for descriptor in MacFSWQueryFieldCatalog.descriptors {
            XCTAssertTrue(descriptor.aliases.contains(descriptor.canonicalKey), "canonical key \(descriptor.canonicalKey) must be an alias of \(descriptor.field)")
            for alias in descriptor.aliases {
                XCTAssertTrue(seenAliases.insert(alias).inserted, "alias \(alias) is claimed by more than one field")
            }
        }
    }

    func testFieldCatalogLookupMatchesLegacyAliases() {
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "op"), .eventType)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "eventtype"), .eventType)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "opclass"), .operationClass)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "path.target"), .targetPath)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "src"), .sourcePath)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "pname"), .processName)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "process.id"), .pid)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "process.executable"), .executable)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "process.signingid"), .signingID)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "process.teamid"), .teamID)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "platform.binary"), .platformBinary)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "user.id"), .uid)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "group.id"), .gid)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "uid/gid"), .uidGid)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "uuid"), .eventID)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "sequence"), .sequence)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "ts"), .timestamp)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "raw.type"), .rawType)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "rawversion"), .esVersion)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "flag"), .flags)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "metadata"), .parameters)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "writeevent"), .mutation)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "apple.controlled"), .appleControlled)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "audit.token"), .auditToken)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "codehash"), .cdhash)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "q"), .any)

        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: "Event_Type"), .eventType)
        XCTAssertEqual(MacFSWQueryFieldCatalog.field(forRawKey: " TEAM-ID "), .teamID)
        XCTAssertNil(MacFSWQueryFieldCatalog.field(forRawKey: "bogus"))
    }

    func testCanonicalKeyResolvesToItsOwnField() {
        for descriptor in MacFSWQueryFieldCatalog.descriptors {
            XCTAssertEqual(
                MacFSWQueryFieldCatalog.field(forRawKey: descriptor.canonicalKey),
                descriptor.field,
                "canonical key \(descriptor.canonicalKey) must resolve to \(descriptor.field)"
            )
            XCTAssertEqual(MacFSWQueryFieldCatalog.descriptor(for: descriptor.field), descriptor)
        }
    }
}
