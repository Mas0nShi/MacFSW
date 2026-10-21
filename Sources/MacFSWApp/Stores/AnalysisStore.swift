import Foundation
import Observation
import MacFSWAnalysis
import MacFSWCore

@MainActor
@Observable
final class AnalysisStore {
    var selectedProcessID: MacFSWProcessSummary.ID?
    var isRunning = false
    var streamingMarkdown = ""
    var statusText = "Select a process to analyze."
    var runError: MacFSWConnectionTestError?
    var results: [MacFSWAnalysisResult] = []
    var selectedResultID: MacFSWAnalysisResult.ID?
    var connectionTestState: MacFSWConnectionTestState = .idle

    private let llmClient: MacFSWLLMClient
    @ObservationIgnored
    private var analysisTask: Task<Void, Never>?
    @ObservationIgnored
    private var analysisGeneration = 0

    init(llmClient: MacFSWLLMClient) {
        self.llmClient = llmClient
    }

    var selectedAnalysis: MacFSWAnalysisResult? {
        guard let selectedResultID else { return nil }
        return results.first { $0.id == selectedResultID }
    }

    var isTestingConnection: Bool {
        if case .testing = connectionTestState {
            return true
        }
        return false
    }

    func resetConnectionStateIfIdle() {
        if !isTestingConnection {
            connectionTestState = .idle
        }
    }

    func selectProcess(_ summary: MacFSWProcessSummary) {
        selectedProcessID = summary.id
        selectedResultID = nil
        if !isRunning {
            streamingMarkdown = ""
            runError = nil
            statusText = "\(summary.displayName) selected."
        }
    }

    func selectAnalysis(_ result: MacFSWAnalysisResult) {
        selectedResultID = result.id
    }

    func clearHistory() {
        results.removeAll(keepingCapacity: false)
        selectedResultID = nil
    }

    func resetForNewSession() {
        cancelTask()
        selectedProcessID = nil
        isRunning = false
        streamingMarkdown = ""
        statusText = "Select a process to analyze."
        runError = nil
        results = []
        selectedResultID = nil
    }

    func resetSelection() {
        cancelAnalysis()
        selectedProcessID = nil
        streamingMarkdown = ""
        statusText = "Select a process to analyze."
        runError = nil
    }

    func clearProcessSelection() {
        selectedProcessID = nil
    }

    func cancelTask() {
        analysisTask?.cancel()
        analysisTask = nil
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        if isRunning {
            isRunning = false
            statusText = streamingMarkdown.isEmpty ? "Analysis cancelled." : "Analysis cancelled. Partial output is still visible."
        }
    }

    func runAnalysis(
        target: MacFSWProcessSummary?,
        eventStore: MacFSWSQLiteEventStore,
        settings: MacFSWLLMSettings,
        template: MacFSWAnalysisPromptTemplate,
        reportError: @MainActor @escaping (Error) -> Void
    ) {
        guard let target else {
            statusText = "Select a process to analyze."
            return
        }

        analysisTask?.cancel()
        analysisGeneration += 1
        let generation = analysisGeneration
        let client = llmClient
        let startedAt = Date()
        selectedResultID = nil
        streamingMarkdown = ""
        runError = nil
        isRunning = true
        statusText = "Preparing \(target.displayName)..."

        analysisTask = Task { [weak self] in
            do {
                let query = MacFSWEventQuery(processIdentity: target.filterIdentity)
                async let totalCount = eventStore.totalCount(matching: query)
                async let newestEvents = eventStore.events(
                    matching: query,
                    sortOrder: .newestFirst,
                    limit: settings.maxEvents
                )
                let (total, newest) = try await (totalCount, newestEvents)
                let events = Array(newest.reversed())
                let context = MacFSWAnalysisProcessContext(
                    displayName: target.displayName,
                    processName: target.processName,
                    pid: target.pid,
                    executablePath: target.executablePath,
                    signingSummary: target.signingSummary,
                    uid: target.uid,
                    gid: target.gid,
                    eventCount: target.eventCount,
                    isPlatformBinary: target.isPlatformBinary,
                    lifecycle: target.lifecycle.title
                )
                let prepared = MacFSWAnalysisPayloadBuilder.build(
                    process: context,
                    events: events,
                    totalEventCount: total,
                    template: template,
                    outputLanguageName: settings.outputLanguage.promptName(resolvingSystemWith: .current),
                    eventSampleCharacterBudget: settings.promptEventCharacterBudget
                )
                await MainActor.run {
                    guard let self, self.analysisGeneration == generation else {
                        return
                    }
                    self.statusText = "Analyzing \(target.displayName)..."
                }

                let request = MacFSWLLMRequest(
                    settings: settings,
                    systemPrompt: prepared.systemPrompt,
                    userPrompt: prepared.userPrompt
                )
                let stream = try await client.streamAnalysis(request: request)
                var buffer: [String] = []
                var lastPublishedLength = 0
                var lastPublishedAt = ContinuousClock.now - .seconds(1)
                let coalesceWindow = Duration.milliseconds(16)

                for try await delta in stream {
                    try Task.checkCancellation()
                    buffer.append(delta.text)
                    let now = ContinuousClock.now
                    // Publish the FIRST delta immediately so tokens appear as
                    // soon as bytes land, then coalesce further deltas that
                    // arrive within one display frame — MarkdownView reparses
                    // the whole buffer on every input change, so back-to-back
                    // updates within the same frame are pure waste. Slow
                    // models still see each delta ship on arrival; fast
                    // models get frame-rate batching for free.
                    if now - lastPublishedAt < coalesceWindow {
                        continue
                    }
                    let joined = buffer.joined()
                    guard joined.count != lastPublishedLength else {
                        continue
                    }
                    lastPublishedLength = joined.count
                    lastPublishedAt = now
                    await MainActor.run {
                        guard let self, self.analysisGeneration == generation else {
                            return
                        }
                        self.streamingMarkdown = joined
                    }
                }
                let accumulated = buffer.joined()
                if accumulated.count != lastPublishedLength {
                    await MainActor.run {
                        guard let self, self.analysisGeneration == generation else {
                            return
                        }
                        self.streamingMarkdown = accumulated
                    }
                }

                let finalMarkdown = accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No text was returned by the configured model."
                    : accumulated
                let result = MacFSWAnalysisResult(
                    processID: target.id,
                    processDisplayName: target.displayName,
                    createdAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    scope: "Selected process, current session",
                    providerSummary: "\(settings.endpoint.rawValue) · \(settings.model)",
                    totalEventCount: prepared.totalEventCount,
                    fetchedEventCount: prepared.fetchedEventCount,
                    sampledEventCount: prepared.sampledEventCount,
                    pathCount: prepared.pathCount,
                    operationCount: prepared.operationCount,
                    templateName: template.name,
                    markdown: finalMarkdown
                )
                await MainActor.run {
                    guard let self, self.analysisGeneration == generation else {
                        return
                    }
                    self.results.insert(result, at: 0)
                    self.selectedResultID = result.id
                    self.streamingMarkdown = ""
                    self.isRunning = false
                    self.analysisTask = nil
                    self.statusText = "Completed \(target.displayName)."
                }
            } catch {
                await MainActor.run {
                    guard let self, self.analysisGeneration == generation else {
                        return
                    }
                    if ErrorPresentation.isCancellationError(error) {
                        self.statusText = self.streamingMarkdown.isEmpty ? "Analysis cancelled." : "Analysis cancelled. Partial output is still visible."
                    } else {
                        self.statusText = error.userFacingMessage
                        self.runError = Self.analysisError(from: error, settings: settings)
                        reportError(error)
                    }
                    self.isRunning = false
                    self.analysisTask = nil
                }
            }
        }
    }

    func testConnection(settings inputSettings: MacFSWLLMSettings) {
        guard !isTestingConnection else {
            return
        }
        connectionTestState = .testing
        var settings = inputSettings
        settings.streamResponses = false
        settings.maxEvents = 1
        let client = llmClient
        Task { [weak self] in
            do {
                let request = MacFSWLLMRequest(
                    settings: settings,
                    systemPrompt: "You are a connection test endpoint.",
                    userPrompt: "Reply with OK."
                )
                let stream = try await client.streamAnalysis(request: request)
                var receivedText = false
                for try await delta in stream {
                    if !delta.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        receivedText = true
                        break
                    }
                }
                await MainActor.run {
                    self?.connectionTestState = receivedText
                        ? .succeeded("Connection OK")
                        : .failed(MacFSWConnectionTestError(
                            title: "No Text Returned",
                            message: "The provider accepted the request but did not return text output.",
                            diagnostic: "Endpoint: \(settings.endpoint.rawValue)\nModel: \(settings.model)\nBase URL: \(settings.baseURL)"
                        ))
                }
            } catch {
                await MainActor.run {
                    self?.connectionTestState = .failed(Self.connectionTestError(from: error, settings: settings))
                }
            }
        }
    }

    private static func connectionTestError(
        from error: Error,
        settings: MacFSWLLMSettings
    ) -> MacFSWConnectionTestError {
        let endpointURL = MacFSWLLMClient.endpointURL(baseURL: settings.baseURL, endpoint: settings.endpoint)?
            .absoluteString ?? "\(settings.baseURL)\(settings.endpoint.rawValue)"
        if let clientError = error as? MacFSWLLMClientError,
           let details = clientError.httpDetails {
            return MacFSWConnectionTestError(
                title: details.title,
                message: details.message,
                diagnostic: [
                    "Endpoint: \(endpointURL)",
                    "Model: \(settings.model)",
                    "",
                    details.diagnosticText,
                ].joined(separator: "\n")
            )
        }
        if let clientError = error as? MacFSWLLMClientError,
           let body = clientError.streamErrorBody {
            let message = MacFSWLLMDeltaExtractor.errorMessages(from: body).first ?? clientError.localizedDescription
            return MacFSWConnectionTestError(
                title: "Provider Stream Error",
                message: message,
                diagnostic: [
                    "Endpoint: \(endpointURL)",
                    "Model: \(settings.model)",
                    "",
                    body,
                ].joined(separator: "\n")
            )
        }

        let message = (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
        return MacFSWConnectionTestError(
            title: "Connection Test Failed",
            message: message,
            diagnostic: [
                "Endpoint: \(endpointURL)",
                "Model: \(settings.model)",
                "",
                message,
            ].joined(separator: "\n")
        )
    }

    private static func analysisError(
        from error: Error,
        settings: MacFSWLLMSettings
    ) -> MacFSWConnectionTestError {
        var analysisError = connectionTestError(from: error, settings: settings)
        if analysisError.title == "Connection Test Failed" {
            analysisError.title = "Analysis Request Failed"
        }
        return analysisError
    }
}
