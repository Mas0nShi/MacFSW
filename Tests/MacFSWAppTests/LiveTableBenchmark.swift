import AppKit
import QuartzCore
import MacFSWAnalysis
import MacFSWCore
import SwiftUI
import XCTest
@testable import MacFSWApp

/// Opt-in smoothness of the live monitor:
/// `MACFSW_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter LiveTableBenchmark`.
/// Shows a real window for a few seconds, feeds it events, and counts
/// frames that missed the display refresh. Knobs:
/// `MACFSW_BENCH_RATE` (events/s, default 2000), `MACFSW_BENCH_SECONDS`
/// (default 3), `MACFSW_BENCH_VIEW` (`monitor`, `sidebar`, `processes`,
/// `ops`, `commandbar`, `status`; default the whole window).
@MainActor
final class LiveTableBenchmark: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["MACFSW_BENCH"] != nil else {
            throw XCTSkip("set MACFSW_BENCH")
        }
    }

    func testCellConfigurationCost() {
        let cell = EventTableCellView(identifier: NSUserInterfaceItemIdentifier("bench"))
        let rows = Self.events(count: 1_000, startingAt: 0).map(MacFSWEventRowSummary.init(event:))
        let start = ContinuousClock.now
        for row in rows {
            for column in EventTableColumn.allCases {
                column.configure(cell, with: row)
            }
        }
        let perRow = (ContinuousClock.now - start) / rows.count
        print("BENCH cell: \(perRow) per row (\(EventTableColumn.allCases.count) columns)")
        for column in EventTableColumn.allCases {
            let start = ContinuousClock.now
            for row in rows {
                column.configure(cell, with: row)
            }
            print("BENCH cell \(column.rawValue): \((ContinuousClock.now - start) / rows.count)")
        }
    }

    func testLiveFeed() async throws {
        let environment = ProcessInfo.processInfo.environment
        try await measureLiveFeed(
            eventsPerSecond: environment["MACFSW_BENCH_RATE"].flatMap { Int($0) } ?? 2_000,
            seconds: environment["MACFSW_BENCH_SECONDS"].flatMap { Int($0) } ?? 3
        )
    }

    /// Main-thread cost of one scroll step: a screenful by default (a jump to
    /// the newest row), or `MACFSW_BENCH_STEP_ROWS` rows (a live-follow
    /// frame). `MACFSW_BENCH_VIEW=monitor|table` hosts less of the window.
    func testScreenOfNewRows() async throws {
        let model = makeCoordinator()
        _ = try await model.session.eventStore.appendReturningEvents(Self.events(count: 20_000, startingAt: 0))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1440, height: 860), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        switch ProcessInfo.processInfo.environment["MACFSW_BENCH_VIEW"] {
        case "monitor":
            window.contentView = NSHostingView(rootView: MonitorView().environment(model))
        case "table":
            window.contentView = NSHostingView(rootView: MonitorTableOnly().environment(model))
        default:
            window.contentView = NSHostingView(rootView: DashboardView().environment(model))
        }
        window.orderFrontRegardless()
        model.monitor.pauseFollowing()
        await model.monitor.refreshFilteredEvents()
        try await Task.sleep(for: .milliseconds(500))

        func tables(in view: NSView) -> [NSTableView] {
            ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables(in:))
        }
        let table = try XCTUnwrap(tables(in: window.contentView!).first)
        let clipView = try XCTUnwrap(table.enclosingScrollView?.contentView)
        var times: [Duration] = []
        for screen in 1...(Int(ProcessInfo.processInfo.environment["MACFSW_BENCH_SCREENS"] ?? "") ?? 60) {
            // Rows load a page at a time; let the page for this screen land
            // so the timing covers drawing real content.
            let step = ProcessInfo.processInfo.environment["MACFSW_BENCH_STEP_ROWS"].flatMap { Double($0) }.map { CGFloat($0) * table.rowHeight } ?? clipView.bounds.height
            let y = CGFloat(screen) * step
            model.monitor.requestRows(Range(table.rows(in: NSRect(x: 0, y: y, width: 10, height: clipView.bounds.height))) ?? 0..<0)
            try await Task.sleep(for: .milliseconds(30))
            let start = ContinuousClock.now
            clipView.setBoundsOrigin(NSPoint(x: 0, y: y))
            table.enclosingScrollView?.reflectScrolledClipView(clipView)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            times.append(ContinuousClock.now - start)
        }
        window.close()
        let sorted = times.sorted()
        let stepRows = ProcessInfo.processInfo.environment["MACFSW_BENCH_STEP_ROWS"] ?? "a screen of"
        print("BENCH scroll by \(stepRows) rows: p50=\(sorted[sorted.count / 2]) p95=\(sorted[sorted.count * 95 / 100])")
    }

    /// Clearing a large session while events stream in: how soon the view
    /// empties, how long the store takes, and whether frames hitch.
    func testClearWhileLive() async throws {
        let model = makeCoordinator()
        let total = ProcessInfo.processInfo.environment["MACFSW_BENCH_EVENTS"].flatMap { Int($0) } ?? 100_000
        var next = 0
        while next < total {
            let batch = Self.events(count: 2_000, startingAt: next)
            _ = try await model.session.eventStore.appendReturningEvents(batch)
            next += batch.count
        }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1440, height: 860), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DashboardView().environment(model))
        window.orderFrontRegardless()
        model.monitor.prepareForLiveCapture()
        await model.monitor.refreshFilteredEvents()
        try await Task.sleep(for: .milliseconds(500))

        let frames = FrameRecorder(view: window.contentView!)
        frames.start()
        let clicked = ContinuousClock.now
        model.clearView()
        let viewEmptied = ContinuousClock.now - clicked
        while try await model.session.eventStore.count(matching: MacFSWEventQuery()) > 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let storeCleared = ContinuousClock.now - clicked
        for _ in 0..<60 {
            let batch = try await model.session.eventStore.appendReturningEvents(Self.events(count: 30, startingAt: next))
            next += 30
            model.ingest(batch.events)
            try await Task.sleep(for: .milliseconds(16))
        }
        frames.stop()
        window.close()
        let worst = frames.intervals.max() ?? .zero
        print("BENCH clear \(total) while live: view emptied in \(viewEmptied), store cleared in \(storeCleared), worst frame \(worst), rows after=\(model.monitor.visibleEventCount)")
    }

    private func measureLiveFeed(eventsPerSecond: Int, seconds: Int) async throws {
        let model = makeCoordinator()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1440, height: 860), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        switch ProcessInfo.processInfo.environment["MACFSW_BENCH_VIEW"] {
        case "monitor":
            window.contentView = NSHostingView(rootView: MonitorView().environment(model))
        case "sidebar":
            window.contentView = NSHostingView(rootView: SidebarView().environment(model))
        case "processes":
            window.contentView = NSHostingView(rootView: ProcessFilterPane().frame(width: 280).environment(model))
        case "ops":
            window.contentView = NSHostingView(rootView: OperationStatsPane().frame(width: 280).environment(model))
        case "commandbar":
            window.contentView = NSHostingView(rootView: VStack { MonitorCommandBar(); Spacer() }.environment(model))
        case "status":
            window.contentView = NSHostingView(rootView: VStack { Spacer(); StatusBar() }.environment(model))
        default:
            window.contentView = NSHostingView(rootView: DashboardView().environment(model))
        }
        // On screen, so drawing goes through the real compositor path.
        window.orderFrontRegardless()
        model.monitor.prepareForLiveCapture()
        try await Task.sleep(for: .milliseconds(500))

        let frames = FrameRecorder(view: window.contentView!)
        let tick = Duration.milliseconds(16)
        let perTick = eventsPerSecond / 60
        let ticks = seconds * 60
        var ingestTimes: [Duration] = []
        var next = 0
        // Events are generated before the timed run so their construction
        // does not count against the main thread.
        let pool = Self.events(count: perTick * ticks, startingAt: 0)
        frames.start()
        for _ in 0..<ticks {
            let start = ContinuousClock.now
            let slice = Array(pool[next..<(next + perTick)])
            next += perTick
            let batch = try await model.session.eventStore.appendReturningEvents(slice)
            let ingestStart = ContinuousClock.now
            model.ingest(batch.events)
            ingestTimes.append(ContinuousClock.now - ingestStart)
            let elapsed = ContinuousClock.now - start
            if elapsed < tick {
                try await Task.sleep(for: tick - elapsed)
            }
        }
        frames.stop()
        window.close()
        let intervals = frames.intervals

        func ms(_ duration: Duration) -> String {
            String(format: "%.2fms", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1e3)
        }
        func percentile(_ values: [Duration], _ p: Double) -> Duration {
            let sorted = values.sorted()
            return sorted.isEmpty ? .zero : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        let refresh = frames.refreshInterval
        let hitches = intervals.filter { $0 > refresh * 1.5 }
        let hitchTime = hitches.reduce(Duration.zero) { $0 + ($1 - refresh) }
        print("BENCH live \(eventsPerSecond)/s: rows=\(model.monitor.visibleEventCount) frames=\(intervals.count)"
            + " refresh=\(ms(refresh)) frame p95=\(ms(percentile(intervals, 0.95))) max=\(ms(intervals.max() ?? .zero))"
            + " hitches=\(hitches.count) hitch-time=\(ms(hitchTime))"
            + " ingest p95=\(ms(percentile(ingestTimes, 0.95)))")
    }

    private func makeCoordinator() -> MacFSWAppCoordinator {
        let defaults = UserDefaults(suiteName: "LiveTableBenchmark-\(UUID().uuidString)")!
        return MacFSWAppCoordinator(environment: MacFSWAppEnvironment(
            appVersion: "bench",
            captureClient: MacFSWXPCCaptureClient(serviceName: "invalid.macfsw.bench", healthTimeoutSeconds: 1),
            extensionInstaller: BenchInstaller(),
            settingsStore: MacFSWSettingsStore(defaults: defaults),
            llmClient: MacFSWLLMClient()
        ))
    }

    private static func events(count: Int, startingAt start: Int) -> [MacFSWFileEvent] {
        let processes = (0..<8).map {
            MacFSWProcessIdentity(pid: Int32(400 + $0), auditToken: "t\($0)", executablePath: "/usr/bin/tool\($0)", processName: "tool\($0)", signingID: "com.example.tool\($0)")
        }
        let types: [MacFSWEventType] = [.write, .create, .rename, .unlink, .chmod, .write, .open]
        return (start..<(start + count)).map { i in
            let type = types[i % types.count]
            return MacFSWFileEvent(
                eventType: type,
                process: processes[i % processes.count],
                targetPath: "/Users/me/Library/Caches/com.example/item-\(i).db",
                sourcePath: type == .rename ? "/private/tmp/staging-\(i)" : nil,
                parameters: type == .chmod ? [MacFSWEventParameter(key: "mode", label: "Mode", value: "0755"), MacFSWEventParameter(key: "current_mode", label: "Current Mode", value: "0644")] : []
            )
        }
    }
}

private struct MonitorTableOnly: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        @Bindable var monitor = model.monitor
        EventTableView(
            rowCount: monitor.visibleEventCount,
            cacheVersion: monitor.rowCacheVersion,
            cacheResetSerial: monitor.rowCacheResetSerial,
            resetSerial: monitor.tableResetSerial,
            selectedEventID: $monitor.selectedEventID,
            selectedRow: monitor.selectedRow,
            followMode: monitor.followMode,
            scrollToLiveSerial: monitor.scrollToLiveSerial,
            selectionResetSerial: monitor.selectionResetSerial,
            rowProvider: { monitor.cachedRow(at: $0) },
            requestRows: { monitor.requestRows($0) },
            onUserWillSelect: { _ in },
            onUserSelected: { _, _ in },
            onClearSelection: {},
            onFollowChanged: { _ in },
            onRowAction: { _, _ in }
        )
    }
}

/// Records the interval between display-link callbacks: a frame that
/// takes longer than the refresh interval is a visible hitch.
@MainActor
private final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private(set) var intervals: [Duration] = []
    private(set) var refreshInterval = Duration.milliseconds(16)

    init(view: NSView) {
        super.init()
        link = view.displayLink(target: self, selector: #selector(frame(_:)))
    }

    func start() {
        link?.add(to: .main, forMode: .common)
    }

    func stop() {
        link?.invalidate()
    }

    @objc private func frame(_ link: CADisplayLink) {
        refreshInterval = .microseconds(Int((link.targetTimestamp - link.timestamp) * 1_000_000))
        if let last {
            intervals.append(.microseconds(Int((link.timestamp - last) * 1_000_000)))
        }
        last = link.timestamp
    }
}

@MainActor
private final class BenchInstaller: SystemExtensionInstalling {
    var onStateChange: ((MacFSWSystemExtensionInstallState, String) -> Void)?
    var onUpdateStarted: ((String, String) -> Void)?
    func activate() {}
    func checkInstalledVersion() {}
    func openLoginItemsSettings() {}
    func openFullDiskAccessSettings() {}
}
