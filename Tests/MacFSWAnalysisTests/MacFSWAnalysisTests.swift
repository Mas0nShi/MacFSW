import XCTest
import MacFSWCore
@testable import MacFSWAnalysis

final class MacFSWAnalysisTests: XCTestCase {
    func testRequestBodiesAndURLsForSupportedEndpoints() throws {
        let baseSettings = MacFSWLLMSettings(
            baseURL: "https://api.example.test/v1",
            apiKey: "secret",
            model: "model-a",
            tokenBudget: 321,
            streamResponses: true
        )

        for endpoint in MacFSWLLMEndpoint.allCases {
            var settings = baseSettings
            settings.endpoint = endpoint
            let request = MacFSWLLMRequest(settings: settings, systemPrompt: "system", userPrompt: "user")
            let urlRequest = try MacFSWLLMClient().makeURLRequest(for: request)

            XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.example.test\(endpoint.rawValue)")
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer secret")

            let body = try XCTUnwrap(urlRequest.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "model-a")
            XCTAssertEqual(json["stream"] as? Bool, true)
            XCTAssertNil(json["apiKey"])

            switch endpoint {
            case .responses:
                XCTAssertNotNil(json["input"])
                XCTAssertEqual(json["max_output_tokens"] as? Int, 321)
            case .chatCompletions:
                XCTAssertNotNil(json["messages"])
                XCTAssertEqual(json["max_tokens"] as? Int, 321)
            case .completions:
                XCTAssertTrue((json["prompt"] as? String)?.contains("system") == true)
                XCTAssertEqual(json["max_tokens"] as? Int, 321)
            }
        }
    }

    func testSSEParserSupportsMultilineDataAndDone() {
        var parser = MacFSWSSEParser()

        XCTAssertEqual(parser.feed(line: ": keepalive"), [])
        XCTAssertEqual(parser.feed(line: "event: response.output_text.delta"), [])
        XCTAssertEqual(parser.feed(line: "data: {\"a\":1"), [])
        XCTAssertEqual(parser.feed(line: "data: ,\"b\":2}"), [])
        XCTAssertEqual(
            parser.feed(line: ""),
            [MacFSWSSEEvent(event: "response.output_text.delta", data: "{\"a\":1\n,\"b\":2}")]
        )
        XCTAssertEqual(parser.feed(line: "data: [DONE]"), [])
        XCTAssertEqual(parser.feed(line: "\r"), [MacFSWSSEEvent(event: nil, data: "[DONE]")])
    }

    func testDeltaExtractionToleratesNewlineSeparatedJSONPayloads() throws {
        let payload = """
        {"type":"response.output_text.delta","delta":"alpha"}
        {"choices":[{"delta":{"content":"beta"}}]}
        """

        XCTAssertEqual(
            try MacFSWLLMDeltaExtractor.deltaTexts(from: payload, endpoint: .responses),
            ["alpha", "beta"]
        )
    }

    func testStreamErrorExtractionSupportsProviderErrorEvents() {
        let payload = #"{"type":"error","error":{"message":"model is unavailable","code":"forbidden"}}"#

        XCTAssertEqual(
            MacFSWLLMDeltaExtractor.errorMessages(from: payload),
            ["model is unavailable"]
        )
    }

    func testDeltaExtractionForResponsesChatAndCompletions() throws {
        let responsesDelta = #"{"type":"response.output_text.delta","delta":"alpha"}"#
        XCTAssertEqual(
            try MacFSWLLMDeltaExtractor.deltaTexts(from: responsesDelta, endpoint: .responses),
            ["alpha"]
        )

        let responsesFinal = #"{"output":[{"content":[{"type":"output_text","text":"final"}]}]}"#
        XCTAssertEqual(
            try MacFSWLLMDeltaExtractor.deltaTexts(from: responsesFinal, endpoint: .responses),
            ["final"]
        )

        let chat = #"{"choices":[{"delta":{"content":"beta"}}]}"#
        XCTAssertEqual(
            try MacFSWLLMDeltaExtractor.deltaTexts(from: chat, endpoint: .chatCompletions),
            ["beta"]
        )

        let completion = #"{"choices":[{"text":"gamma"}]}"#
        XCTAssertEqual(
            try MacFSWLLMDeltaExtractor.deltaTexts(from: completion, endpoint: .completions),
            ["gamma"]
        )
    }

    func testLLMSettingsEncodingDoesNotPersistAPIKey() throws {
        let settings = MacFSWLLMSettings(apiKey: "do-not-store")
        let data = try JSONEncoder().encode(settings)
        let raw = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(raw.contains("do-not-store"))
        XCTAssertFalse(raw.contains("apiKey"))
    }

    func testHTTPErrorDetailsExtractProviderMessageWithoutLosingRawBody() {
        let body = #"{"error":{"type":"http_error","message":"当前用户、用户组无权限访问该模型","code":"forbidden"}}"#
        let details = MacFSWLLMHTTPErrorDetails(statusCode: 403, body: body)

        XCTAssertEqual(details.title, "HTTP 403 Forbidden")
        XCTAssertEqual(details.providerType, "http_error")
        XCTAssertEqual(details.providerCode, "forbidden")
        XCTAssertEqual(details.message, "当前用户、用户组无权限访问该模型")
        XCTAssertTrue(details.diagnosticText.contains(body))
    }

    func testKeychainWrapperReadsWritesAndDeletesAPIKey() throws {
        let service = "com.macfsw.tests.llm.\(UUID().uuidString)"
        let account = "default"
        try? MacFSWKeychain.delete(service: service, account: account)
        addTeardownBlock {
            try? MacFSWKeychain.delete(service: service, account: account)
        }

        XCTAssertNil(try MacFSWKeychain.read(service: service, account: account))

        try MacFSWKeychain.save("first-key", service: service, account: account)
        XCTAssertEqual(try MacFSWKeychain.read(service: service, account: account), "first-key")

        try MacFSWKeychain.save("second-key", service: service, account: account)
        XCTAssertEqual(try MacFSWKeychain.read(service: service, account: account), "second-key")

        try MacFSWKeychain.delete(service: service, account: account)
        XCTAssertNil(try MacFSWKeychain.read(service: service, account: account))
    }

    func testPayloadBuilderOrdersRecentEventsAndIncludesOperationParameters() {
        let process = MacFSWProcessIdentity(
            pid: 700,
            auditToken: "payload",
            executablePath: "/usr/bin/chmod",
            processName: "chmod",
            signingID: "com.example.chmod"
        )
        let events = [
            MacFSWFileEvent(sequence: 3, eventType: .unlink, process: process, targetPath: "/tmp/old"),
            MacFSWFileEvent(
                sequence: 1,
                eventType: .chmod,
                process: process,
                targetPath: "/tmp/target",
                parameters: [
                    MacFSWEventParameter(key: "mode", label: "Mode", value: "0644"),
                    MacFSWEventParameter(key: "current_mode", label: "Current Mode", value: "0755"),
                ]
            ),
            MacFSWFileEvent(sequence: 2, eventType: .rename, process: process, targetPath: "/tmp/new", sourcePath: "/tmp/src"),
        ]
        let context = MacFSWAnalysisProcessContext(
            displayName: "chmod(700)",
            processName: "chmod",
            pid: 700,
            executablePath: "/usr/bin/chmod",
            signingSummary: "com.example.chmod",
            uid: 501,
            gid: 20,
            eventCount: 10,
            isPlatformBinary: false,
            lifecycle: "Exited"
        )

        let prepared = MacFSWAnalysisPayloadBuilder.build(
            process: context,
            events: events,
            totalEventCount: 10,
            maxEventSamples: 3
        )

        XCTAssertEqual(prepared.eventCount, 10)
        XCTAssertEqual(prepared.payloadEventCount, 3)
        XCTAssertTrue(prepared.userPrompt.contains("mode 0644"))
        XCTAssertTrue(prepared.userPrompt.contains("source=/tmp/src"))
        XCTAssertLessThan(
            prepared.userPrompt.range(of: "seq=1")!.lowerBound,
            prepared.userPrompt.range(of: "seq=3")!.lowerBound
        )
    }
}
