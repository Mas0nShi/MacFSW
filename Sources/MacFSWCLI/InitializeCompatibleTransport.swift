import Foundation
import Logging
import MCP

/// Hands the SDK an `initialize` request it can decode.
///
/// MCP lets a client describe experimental capabilities as objects, and
/// Codex and ChatGPT do. swift-sdk 0.12 types them `[String: String]` and
/// fails the whole handshake (modelcontextprotocol/swift-sdk#287, #262).
/// MacFSW uses no client experimental capability, so they are dropped
/// before the SDK sees the request. Remove this once the SDK decodes them.
actor InitializeCompatibleTransport: Transport {
    nonisolated let logger = Logger(label: "macfsw.mcp.transport")
    private let base: any Transport

    init(_ base: any Transport) {
        self.base = base
    }

    func connect() async throws {
        try await base.connect()
    }

    func disconnect() async {
        await base.disconnect()
    }

    func send(_ data: Data) async throws {
        try await base.send(data)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in await base.receive() {
                        continuation.yield(Self.decodable(data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `data` with an initialize request's experimental capabilities
    /// removed; every other message is passed through untouched.
    static func decodable(_ data: Data) -> Data {
        guard data.range(of: Data(#""experimental""#.utf8)) != nil,
              var message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["method"] as? String == "initialize",
              var params = message["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              capabilities.removeValue(forKey: "experimental") != nil else {
            return data
        }
        params["capabilities"] = capabilities
        message["params"] = params
        return (try? JSONSerialization.data(withJSONObject: message)) ?? data
    }
}
