import Foundation

public struct MacFSWLLMRequest: Equatable, Sendable {
    public var settings: MacFSWLLMSettings
    public var systemPrompt: String
    public var userPrompt: String

    public init(settings: MacFSWLLMSettings, systemPrompt: String, userPrompt: String) {
        self.settings = settings
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
    }
}

public struct MacFSWLLMDelta: Equatable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct MacFSWLLMHTTPErrorDetails: Equatable, Sendable {
    public var statusCode: Int
    public var statusText: String
    public var providerMessage: String?
    public var providerType: String?
    public var providerCode: String?
    public var rawBody: String

    public var title: String {
        statusText.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode) \(statusText)"
    }

    public var message: String {
        if let providerMessage, !providerMessage.isEmpty {
            return providerMessage
        }
        return rawBody.isEmpty ? "The provider rejected the request." : rawBody
    }

    public init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.statusText = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        self.rawBody = body

        let parsed = Self.parseProviderError(body)
        self.providerMessage = parsed.message
        self.providerType = parsed.type
        self.providerCode = parsed.code
    }

    public var diagnosticText: String {
        var lines = [title]
        if let providerType, !providerType.isEmpty {
            lines.append("type: \(providerType)")
        }
        if let providerCode, !providerCode.isEmpty {
            lines.append("code: \(providerCode)")
        }
        if let providerMessage, !providerMessage.isEmpty {
            lines.append("message: \(providerMessage)")
        }
        if !rawBody.isEmpty {
            lines.append("")
            lines.append(rawBody)
        }
        return lines.joined(separator: "\n")
    }

    private static func parseProviderError(_ body: String) -> (message: String?, type: String?, code: String?) {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return (nil, nil, nil)
        }

        let dictionary: [String: Any]?
        if let root = object as? [String: Any],
           let nested = root["error"] as? [String: Any] {
            dictionary = nested
        } else {
            dictionary = object as? [String: Any]
        }

        guard let dictionary else {
            return (nil, nil, nil)
        }

        return (
            stringValue(for: ["message", "detail", "error_description"], in: dictionary),
            stringValue(for: ["type", "error", "error_type"], in: dictionary),
            stringValue(for: ["code", "error_code"], in: dictionary)
        )
    }

    private static func stringValue(for keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            guard let value = dictionary[key] else {
                continue
            }
            if let string = value as? String {
                return string
            }
            if !(value is NSNull) {
                return String(describing: value)
            }
        }
        return nil
    }
}

public enum MacFSWLLMClientError: Error, LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case missingModel
    case invalidBaseURL(String)
    case invalidRequestBody
    case httpError(statusCode: Int, body: String)
    case streamError(body: String)
    case noTextInResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Configure an LLM API key in Settings before running analysis."
        case .missingModel:
            return "Configure an LLM model in Settings before running analysis."
        case .invalidBaseURL(let url):
            return "Invalid LLM base URL: \(url)"
        case .invalidRequestBody:
            return "Failed to build the LLM request body."
        case .httpError(let statusCode, let body):
            let details = MacFSWLLMHTTPErrorDetails(statusCode: statusCode, body: body)
            return "LLM request failed with \(details.title): \(details.message)"
        case .streamError(let body):
            if let message = MacFSWLLMDeltaExtractor.errorMessages(from: body).first {
                return "LLM stream failed: \(message)"
            }
            return body.isEmpty ? "LLM stream failed." : "LLM stream failed: \(body)"
        case .noTextInResponse:
            return "The LLM response did not contain text output."
        }
    }

    public var httpDetails: MacFSWLLMHTTPErrorDetails? {
        guard case .httpError(let statusCode, let body) = self else {
            return nil
        }
        return MacFSWLLMHTTPErrorDetails(statusCode: statusCode, body: body)
    }

    public var streamErrorBody: String? {
        guard case .streamError(let body) = self else {
            return nil
        }
        return body
    }
}

public final class MacFSWLLMClient: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func streamAnalysis(request: MacFSWLLMRequest) async throws -> AsyncThrowingStream<MacFSWLLMDelta, Error> {
        let urlRequest = try makeURLRequest(for: request)
        if request.settings.streamResponses {
            return stream(urlRequest: urlRequest, endpoint: request.settings.endpoint)
        }
        return nonStreaming(urlRequest: urlRequest, endpoint: request.settings.endpoint)
    }

    public func makeURLRequest(for request: MacFSWLLMRequest) throws -> URLRequest {
        var settings = request.settings
        settings.apiKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.baseURL = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settings.apiKey.isEmpty else {
            throw MacFSWLLMClientError.missingAPIKey
        }
        guard !settings.model.isEmpty else {
            throw MacFSWLLMClientError.missingModel
        }
        guard let url = Self.endpointURL(baseURL: settings.baseURL, endpoint: settings.endpoint) else {
            throw MacFSWLLMClientError.invalidBaseURL(settings.baseURL)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = TimeInterval(settings.timeoutSeconds)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(settings.streamResponses ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try Self.requestBody(for: request)
        return urlRequest
    }

    public static func endpointURL(baseURL: String, endpoint: MacFSWLLMEndpoint) -> URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme != nil,
              components.host != nil else {
            return nil
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var endpointPath = endpoint.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.lowercased().split(separator: "/").last == "v1",
           endpointPath.lowercased().hasPrefix("v1/") {
            endpointPath = String(endpointPath.dropFirst(3))
        }
        let merged = ([basePath, endpointPath].filter { !$0.isEmpty }).joined(separator: "/")
        components.path = "/" + merged
        return components.url
    }

    public static func requestBody(for request: MacFSWLLMRequest) throws -> Data {
        var settings = request.settings
        settings.model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any]
        switch settings.endpoint {
        case .responses:
            body = [
                "model": settings.model,
                "input": [
                    ["role": "developer", "content": request.systemPrompt],
                    ["role": "user", "content": request.userPrompt],
                ],
                "max_output_tokens": settings.tokenBudget,
                "stream": settings.streamResponses,
            ]
        case .chatCompletions:
            body = [
                "model": settings.model,
                "messages": [
                    ["role": "system", "content": request.systemPrompt],
                    ["role": "user", "content": request.userPrompt],
                ],
                "max_tokens": settings.tokenBudget,
                "stream": settings.streamResponses,
            ]
        case .completions:
            body = [
                "model": settings.model,
                "prompt": "\(request.systemPrompt)\n\n\(request.userPrompt)",
                "max_tokens": settings.tokenBudget,
                "stream": settings.streamResponses,
            ]
        }
        guard JSONSerialization.isValidJSONObject(body) else {
            throw MacFSWLLMClientError.invalidRequestBody
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private func stream(
        urlRequest: URLRequest,
        endpoint: MacFSWLLMEndpoint
    ) -> AsyncThrowingStream<MacFSWLLMDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    guard 200...299 ~= httpResponse.statusCode else {
                        let body = try await Self.collectBody(from: bytes)
                        throw MacFSWLLMClientError.httpError(statusCode: httpResponse.statusCode, body: body)
                    }

                    var parser = MacFSWSSEParser()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let events = parser.feed(line: line)
                        for event in events {
                            if event.data == "[DONE]" {
                                continuation.finish()
                                return
                            }
                            if event.event == "error" || !MacFSWLLMDeltaExtractor.errorMessages(from: event.data).isEmpty {
                                throw MacFSWLLMClientError.streamError(body: event.data)
                            }
                            for text in try MacFSWLLMDeltaExtractor.deltaTexts(from: event.data, endpoint: endpoint) where !text.isEmpty {
                                continuation.yield(MacFSWLLMDelta(text: text))
                            }
                        }
                    }
                    for event in parser.finish() where event.data != "[DONE]" {
                        if event.event == "error" || !MacFSWLLMDeltaExtractor.errorMessages(from: event.data).isEmpty {
                            throw MacFSWLLMClientError.streamError(body: event.data)
                        }
                        for text in try MacFSWLLMDeltaExtractor.deltaTexts(from: event.data, endpoint: endpoint) where !text.isEmpty {
                            continuation.yield(MacFSWLLMDelta(text: text))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func nonStreaming(
        urlRequest: URLRequest,
        endpoint: MacFSWLLMEndpoint
    ) -> AsyncThrowingStream<MacFSWLLMDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (data, response) = try await session.data(for: urlRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    guard 200...299 ~= httpResponse.statusCode else {
                        let body = String(data: data, encoding: .utf8) ?? ""
                        throw MacFSWLLMClientError.httpError(statusCode: httpResponse.statusCode, body: body)
                    }
                    let texts = try MacFSWLLMDeltaExtractor.deltaTexts(from: data, endpoint: endpoint)
                    let text = texts.joined()
                    guard !text.isEmpty else {
                        throw MacFSWLLMClientError.noTextInResponse
                    }
                    continuation.yield(MacFSWLLMDelta(text: text))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static func collectBody(from bytes: URLSession.AsyncBytes, limit: Int = 64 * 1024) async throws -> String {
        var data = Data()
        data.reserveCapacity(min(limit, 4096))
        for try await byte in bytes {
            if data.count >= limit {
                break
            }
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public struct MacFSWSSEEvent: Equatable, Sendable {
    public var event: String?
    public var data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

public struct MacFSWSSEParser: Sendable {
    private var dataBuffer = ""
    private var eventType: String?

    public init() {}

    public mutating func feed(line: String) -> [MacFSWSSEEvent] {
        let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return []
        }

        let field: String
        var value: String
        if let separator = line.firstIndex(of: ":") {
            field = String(line[..<separator])
            value = String(line[line.index(after: separator)...])
            if value.first == " " {
                value.removeFirst()
            }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event":
            eventType = value
        case "data":
            dataBuffer += value
            dataBuffer += "\n"
        default:
            break
        }
        return []
    }

    public mutating func finish() -> [MacFSWSSEEvent] {
        dispatch()
    }

    private mutating func dispatch() -> [MacFSWSSEEvent] {
        guard !dataBuffer.isEmpty else {
            eventType = nil
            return []
        }
        if dataBuffer.last == "\n" {
            dataBuffer.removeLast()
        }
        let event = MacFSWSSEEvent(event: eventType, data: dataBuffer)
        dataBuffer.removeAll(keepingCapacity: true)
        eventType = nil
        return [event]
    }
}

public enum MacFSWLLMDeltaExtractor {
    public static func deltaTexts(from payload: String, endpoint: MacFSWLLMEndpoint) throws -> [String] {
        try deltaTexts(from: Data(payload.utf8), endpoint: endpoint)
    }

    public static func deltaTexts(from data: Data, endpoint: MacFSWLLMEndpoint) throws -> [String] {
        let objects = try jsonObjects(from: data)
        return objects.flatMap { object in
            texts(from: object, endpoint: endpoint)
        }
    }

    public static func errorMessages(from payload: String) -> [String] {
        guard let objects = try? jsonObjects(from: Data(payload.utf8)) else {
            return []
        }
        return objects.compactMap(errorMessage(from:))
    }

    private static func jsonObjects(from data: Data) throws -> [Any] {
        do {
            return [try JSONSerialization.jsonObject(with: data)]
        } catch {
            guard let payload = String(data: data, encoding: .utf8) else {
                throw error
            }
            let lines = payload
                .split(whereSeparator: \.isNewline)
                .map { line -> String in
                    var value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if value.hasPrefix("data:") {
                        value = String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    }
                    return value
                }
                .filter { !$0.isEmpty && $0 != "[DONE]" }
            guard lines.count > 1 else {
                throw error
            }
            return try lines.map { line in
                try JSONSerialization.jsonObject(with: Data(line.utf8))
            }
        }
    }

    private static func texts(from object: Any, endpoint: MacFSWLLMEndpoint) -> [String] {
        let primary: [String]
        switch endpoint {
        case .responses:
            primary = responseTexts(from: object)
        case .chatCompletions:
            primary = chatTexts(from: object)
        case .completions:
            primary = completionTexts(from: object)
        }
        if !primary.isEmpty {
            return primary
        }

        let fallbacks = [
            responseTexts(from: object),
            chatTexts(from: object),
            completionTexts(from: object),
        ]
        return fallbacks.first { !$0.isEmpty } ?? []
    }

    private static func errorMessage(from object: Any) -> String? {
        guard let dictionary = object as? [String: Any] else {
            return nil
        }
        if let type = dictionary["type"] as? String,
           type == "error" || type == "response.failed" {
            return providerErrorMessage(from: dictionary) ?? "The provider returned a stream error."
        }
        if dictionary["error"] != nil {
            return providerErrorMessage(from: dictionary)
        }
        if let response = dictionary["response"] as? [String: Any],
           let status = response["status"] as? String,
           status == "failed" || response["error"] != nil {
            return providerErrorMessage(from: response)
        }
        return nil
    }

    private static func providerErrorMessage(from dictionary: [String: Any]) -> String? {
        if let error = dictionary["error"] as? [String: Any] {
            return stringValue(for: ["message", "detail", "error_description", "code", "type"], in: error)
        }
        if let error = dictionary["error"] as? String {
            return error
        }
        return stringValue(for: ["message", "detail", "error_description"], in: dictionary)
    }

    private static func responseTexts(from object: Any) -> [String] {
        guard let dictionary = object as? [String: Any] else {
            return []
        }
        if let delta = dictionary["delta"] as? String {
            return [delta]
        }
        if let outputText = dictionary["output_text"] as? String {
            return [outputText]
        }
        if let text = dictionary["text"] as? String {
            return [text]
        }
        if let response = dictionary["response"] as? [String: Any] {
            let nested = responseTexts(from: response)
            if !nested.isEmpty {
                return nested
            }
        }
        if let output = dictionary["output"] as? [[String: Any]] {
            return output.flatMap(responseOutputTexts(from:))
        }
        if let choices = dictionary["choices"] as? [[String: Any]] {
            return chatTexts(from: ["choices": choices])
        }
        return []
    }

    private static func responseOutputTexts(from item: [String: Any]) -> [String] {
        if let text = item["text"] as? String {
            return [text]
        }
        if let content = item["content"] as? [[String: Any]] {
            return content.flatMap(contentTexts(from:))
        }
        return []
    }

    private static func chatTexts(from object: Any) -> [String] {
        guard let dictionary = object as? [String: Any],
              let choices = dictionary["choices"] as? [[String: Any]] else {
            return []
        }
        return choices.compactMap { choice in
            if let delta = choice["delta"] as? [String: Any],
               let content = contentTexts(from: delta).first {
                return content
            }
            if let message = choice["message"] as? [String: Any],
               let content = contentTexts(from: message).first {
                return content
            }
            return nil
        }
    }

    private static func completionTexts(from object: Any) -> [String] {
        guard let dictionary = object as? [String: Any],
              let choices = dictionary["choices"] as? [[String: Any]] else {
            return []
        }
        return choices.compactMap { $0["text"] as? String }
    }

    private static func contentTexts(from dictionary: [String: Any]) -> [String] {
        if let content = dictionary["content"] as? String {
            return [content]
        }
        if let text = dictionary["text"] as? String {
            return [text]
        }
        if let content = dictionary["content"] as? [[String: Any]] {
            return content.flatMap(contentTexts(from:))
        }
        if let text = dictionary["text"] as? [String: Any] {
            return contentTexts(from: text)
        }
        if let delta = dictionary["delta"] as? String {
            return [delta]
        }
        if let outputText = dictionary["output_text"] as? String {
            return [outputText]
        }
        return []
    }

    private static func stringValue(for keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            guard let value = dictionary[key] else {
                continue
            }
            if let string = value as? String {
                return string
            }
            if !(value is NSNull) {
                return String(describing: value)
            }
        }
        return nil
    }
}
