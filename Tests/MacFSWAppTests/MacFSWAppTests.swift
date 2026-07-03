import XCTest
import Darwin
import MacFSWAnalysis
import MacFSWCore
@testable import MacFSWApp

final class MacFSWAppTests: XCTestCase {
    func testUserManualLinkTargetsGitHubDocs() {
        XCTAssertEqual(
            MacFSWExternalLinks.userManual.absoluteString,
            "https://github.com/Mas0nShi/MacFSW/blob/main/docs/user-manual.md"
        )
    }

    func testWildcardMatcherIsCaseInsensitiveAndSupportsGlobTokens() {
        XCTAssertTrue(WildcardMatcher.matches("com.*.Helper?", value: "COM.EXAMPLE.Helper1"))
        XCTAssertTrue(WildcardMatcher.matches("*Launch?gents*", value: "/Library/LaunchAgents/test.plist"))
        XCTAssertFalse(WildcardMatcher.matches("com.apple.*", value: "com.example.tool"))
    }

    func testProcessSummaryReducerFiltersAndGroupsProcesses() {
        let running = MacFSWProcessSummary(
            id: "running",
            processName: "Installer",
            pid: 100,
            auditToken: "a",
            executablePath: "/usr/sbin/installer",
            signingSummary: "com.apple.installer",
            uid: 0,
            gid: 0,
            eventCount: 5,
            lastEventNS: 20,
            isPlatformBinary: true,
            lifecycle: .running
        )
        let exited = MacFSWProcessSummary(
            id: "exited",
            processName: "Installer",
            pid: 101,
            auditToken: "b",
            executablePath: "/tmp/installer-helper",
            signingSummary: "com.example.helper",
            uid: 501,
            gid: 20,
            eventCount: 2,
            lastEventNS: 10,
            isPlatformBinary: false,
            lifecycle: .exited
        )

        let included = ProcessSummaryReducer.filteredSummaries([running, exited], query: "install*", includeExited: true)
        let runningOnly = ProcessSummaryReducer.filteredSummaries([running, exited], query: "", includeExited: false)
        let groups = ProcessSummaryReducer.groups(from: included)

        XCTAssertEqual(included.map(\.id), ["running", "exited"])
        XCTAssertEqual(runningOnly.map(\.id), ["running"])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.eventCount, 7)
        XCTAssertEqual(groups.first?.exitedCount, 1)
    }

    func testOperationSummaryReducerAggregatesAndAppliesRows() {
        let initial = OperationSummaryReducer.operationSummaries(from: [
            MacFSWOperationEventSummary(eventType: .write, operationClass: .write, eventCount: 2),
            MacFSWOperationEventSummary(eventType: .unlink, operationClass: .delete, eventCount: 1),
        ])
        let updated = OperationSummaryReducer.applying(rows: [
            MacFSWEventRowSummary(
                id: UUID(),
                sequence: 1,
                timestampNS: 1,
                eventType: .rename,
                operationClass: .link,
                processName: "mv",
                pid: 42,
                targetPath: "/tmp/new",
                sourcePath: "/tmp/old",
                detailSummary: "",
                signingSummary: ""
            )
        ], to: initial)

        let counts = Dictionary(uniqueKeysWithValues: updated.map { ($0.bucket, $0.eventCount) })

        XCTAssertEqual(counts[.write], 2)
        XCTAssertEqual(counts[.delete], 1)
        XCTAssertEqual(counts[.rename], 1)
    }

    func testErrorPresentationDetectsPermissionAndCancellation() {
        XCTAssertTrue(ErrorPresentation.isFullDiskAccessError("ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED rawValue: 4"))
        XCTAssertTrue(ErrorPresentation.isFullDiskAccessError("Needs Full Disk Access"))
        XCTAssertTrue(ErrorPresentation.isCancellationError(CancellationError()))
        XCTAssertFalse(ErrorPresentation.userFacingMessage(TestPlainError()).isEmpty)
    }

    @MainActor
    func testAppPreferencesStoreLoadsAndPersistsDefaults() {
        let suiteName = "MacFSWAppTests.Preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(MacFSWNavigationPage.analysis.rawValue, forKey: "MacFSW.DefaultStartupPage")
        defaults.set(false, forKey: "MacFSW.IncludeExitedProcesses.Default")

        let settingsStore = MacFSWSettingsStore(
            defaults: defaults,
            settingsKey: "MacFSWAppTests.LLM.\(UUID().uuidString)",
            keychainService: "com.macfsw.tests.\(UUID().uuidString)",
            keychainAccount: "default"
        )
        let store = AppPreferencesStore(settingsStore: settingsStore, defaults: defaults)

        XCTAssertEqual(store.defaultStartupPage, .analysis)
        XCTAssertFalse(store.defaultIncludeExitedProcesses)

        store.defaultStartupPage = .monitor
        store.defaultIncludeExitedProcesses = true

        XCTAssertEqual(defaults.string(forKey: "MacFSW.DefaultStartupPage"), MacFSWNavigationPage.monitor.rawValue)
        XCTAssertTrue(defaults.bool(forKey: "MacFSW.IncludeExitedProcesses.Default"))
    }

    @MainActor
    func testQueryHistoryStorePersistsDedupesAndCaps() {
        let suiteName = "MacFSWAppTests.QueryHistory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = QueryHistoryStore(defaults: defaults)
        store.record("  op:rename  ")
        store.record("path:/Library")
        store.record("op:rename")
        store.record("   ")

        XCTAssertEqual(store.entries, ["op:rename", "path:/Library"], "re-recording moves an entry to the front; blanks are ignored")

        for index in 0..<12 {
            store.record("query-\(index)")
        }
        XCTAssertEqual(store.entries.count, 10)
        XCTAssertEqual(store.entries.first, "query-11")

        let reloaded = QueryHistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.entries, store.entries)
    }

    @MainActor
    func testProcessSidebarStoreFiltersExitedProcesses() {
        let running = makeProcessSummary(id: "running", lifecycle: .running)
        let exited = makeProcessSummary(id: "exited", lifecycle: .exited)
        let store = ProcessSidebarStore(includeExitedProcesses: true)

        store.replace(with: [running, exited])
        XCTAssertEqual(store.filteredProcessSummaries.map(\.id), ["running", "exited"])

        store.includeExitedProcesses = false
        XCTAssertEqual(store.filteredProcessSummaries.map(\.id), ["running"])
    }

    @MainActor
    func testAnalysisStoreResetForNewSessionClearsTransientAndHistoryState() {
        let store = AnalysisStore(llmClient: MacFSWLLMClient())
        store.results = [
            MacFSWAnalysisResult(
                processID: "proc",
                processDisplayName: "proc(1)",
                createdAt: Date(),
                durationSeconds: 1,
                scope: "scope",
                providerSummary: "provider",
                eventCount: 10,
                payloadEventCount: 5,
                pathCount: 2,
                operationCount: 3,
                markdown: "# Report"
            )
        ]
        store.selectedProcessID = "proc"
        store.streamingMarkdown = "partial"
        store.runError = MacFSWConnectionTestError(title: "Error", message: "Message", diagnostic: "Diagnostic")

        store.resetForNewSession()

        XCTAssertNil(store.selectedProcessID)
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertTrue(store.streamingMarkdown.isEmpty)
        XCTAssertNil(store.runError)
        XCTAssertEqual(store.statusText, "Select a process to analyze.")
    }

    @MainActor
    func testHealthRefreshFailureChecksInstalledSystemExtensionVersion() {
        let installer = TestSystemExtensionInstaller()
        let store = SystemExtensionStatusStore(installer: installer)

        store.applyHealthRefreshFailure(message: "XPC unavailable")

        XCTAssertEqual(store.installState, .notReady)
        XCTAssertEqual(installer.checkInstalledVersionCallCount, 1)
    }

    private func makeProcessSummary(id: String, lifecycle: MacFSWProcessLifecycle) -> MacFSWProcessSummary {
        MacFSWProcessSummary(
            id: id,
            processName: "Tool",
            pid: id == "running" ? getpid() : 999_999,
            auditToken: id,
            executablePath: "/tmp/tool",
            signingSummary: "com.example.tool",
            uid: 501,
            gid: 20,
            eventCount: 1,
            lastEventNS: id == "running" ? 2 : 1,
            isPlatformBinary: false,
            lifecycle: lifecycle
        )
    }
}

private struct TestPlainError: Error {}

@MainActor
private final class TestSystemExtensionInstaller: SystemExtensionInstalling {
    var onStateChange: ((MacFSWSystemExtensionInstallState, String) -> Void)?
    private(set) var checkInstalledVersionCallCount = 0

    func activate() {}

    func checkInstalledVersion() {
        checkInstalledVersionCallCount += 1
    }

    func resetSubmission() {}

    func openLoginItemsSettings() {}

    func openFullDiskAccessSettings() {}
}
