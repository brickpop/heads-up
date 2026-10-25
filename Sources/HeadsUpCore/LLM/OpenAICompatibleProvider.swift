import Foundation

/// A message as the chat-completions API takes it.
public struct LLMMessage: Equatable, Sendable {
    public enum Role: String, Sendable {
        case system, user, assistant, tool
    }

    public enum Part: Equatable, Sendable {
        case text(String)
        /// "data:image/jpeg;base64,…"
        case imageDataURL(String)
    }

    public struct ToolCall: Equatable, Sendable {
        public let id: String
        public let name: String
        /// The JSON arguments, as the model sent them.
        public let arguments: String

        public init(id: String, name: String, arguments: String) {
            self.id = id
            self.name = name
            self.arguments = arguments
        }
    }

    public let role: Role
    public let parts: [Part]
    /// For a `.tool` message: the call it answers.
    public let toolCallID: String?
    /// For an `.assistant` message: the calls it made.
    public let toolCalls: [ToolCall]

    public init(role: Role, parts: [Part], toolCallID: String? = nil, toolCalls: [ToolCall] = []) {
        self.role = role
        self.parts = parts
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    public static func text(_ role: Role, _ text: String) -> LLMMessage {
        LLMMessage(role: role, parts: [.text(text)])
    }
}

/// A tool the model may call: `{type: "function", function: {name, description, parameters}}`.
public struct LLMTool: Equatable, Sendable {
    public let name: String
    public let description: String
    /// Its JSON schema.
    public let parameters: Data

    public init(name: String, description: String, parameters: Data) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Streams a reply. A protocol only so the chat's tests can use a fake (ADR-001 §8.1).
public protocol LLMProvider: Sendable {
    /// Ends with `.finished`, or throws a `ChatError`.
    func stream(endpoint: Endpoint, messages: [LLMMessage], tools: [LLMTool]) -> AsyncThrowingStream<LLMEvent, Error>
}

/// The one API HeadsUp speaks: `POST <base>/chat/completions` with `stream: true` (ADR-001 §8.1).
/// The token is added by the transport, never here.
public final class OpenAICompatibleProvider: LLMProvider {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    public func stream(endpoint: Endpoint, messages: [LLMMessage], tools: [LLMTool])
        -> AsyncThrowingStream<LLMEvent, Error>
    {
        let (events, continuation) = AsyncThrowingStream<LLMEvent, Error>.makeStream()
        let task = Task {
            do {
                try await self.run(endpoint: endpoint, messages: messages, tools: tools) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return events
    }

    private func run(
        endpoint: Endpoint, messages: [LLMMessage], tools: [LLMTool], yield: (LLMEvent) -> Void
    ) async throws(ChatError) {
        guard let url = endpoint.url("chat/completions"), let base = URL(string: endpoint.baseURL) else {
            throw .badResponse
        }
        let request = HTTPRequest(
            method: "POST", url: url,
            headers: ["Content-Type": "application/json", "Accept": "text/event-stream"],
            body: Self.body(model: endpoint.model, messages: messages, tools: endpoint.tools ? tools : []),
            credential: Origin(endpoint.baseURL).map { .saved(endpointID: endpoint.id, origin: $0) })
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw ChatErrorMapping.map(error, url: base)
        }
        guard response.status == 200 else {
            let body = (try? await response.collect(limit: 64 * 1024)) ?? Data()
            throw ChatErrorMapping.map(
                status: response.status, body: body, headers: response.headers, model: endpoint.model,
                hasToken: endpoint.hasToken, redact: response.redact)
        }

        var parser = SSEParser()
        var stream = ChatCompletionStream(redact: response.redact)
        do {
            for try await chunk in response.body {
                for event in try parser.feed(chunk) {
                    for llmEvent in try stream.read(event) { yield(llmEvent) }
                }
                if stream.isDone { break }
            }
        } catch let error as ChatError {
            throw error
        } catch is SSEParser.TooLong {
            throw .badResponse
        } catch let error as HTTPError {
            throw ChatErrorMapping.map(error, url: base)
        } catch {
            throw .badResponse
        }
        // The body ended without [DONE]: whole only if the model said why it stopped.
        if !stream.isDone {
            guard stream.sawEnd else { throw .badResponse }
            for event in stream.finish() { yield(event) }
        }
    }

    /// The request body: `stream_options.include_usage` is asked for; a server that leaves
    /// usage out is fine.
    static func body(model: String, messages: [LLMMessage], tools: [LLMTool]) -> Data {
        var body: [String: Any] = [
            "model": model, "stream": true, "stream_options": ["include_usage": true],
            "messages": messages.map(wire),
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name, "description": tool.description,
                        "parameters": (try? JSONSerialization.jsonObject(with: tool.parameters)) ?? [String: Any](),
                    ] as [String: Any],
                ] as [String: Any]
            }
        }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    private static func wire(_ message: LLMMessage) -> [String: Any] {
        var wire: [String: Any] = ["role": message.role.rawValue]
        let onlyText = message.parts.allSatisfy { if case .text = $0 { true } else { false } }
        if onlyText {
            let text = message.parts.map { if case .text(let text) = $0 { text } else { "" } }.joined()
            wire["content"] = message.role == .assistant && text.isEmpty && !message.toolCalls.isEmpty ? NSNull() : text
        } else {
            wire["content"] = message.parts.map { part -> [String: Any] in
                switch part {
                case .text(let text): ["type": "text", "text": text]
                case .imageDataURL(let url): ["type": "image_url", "image_url": ["url": url]]
                }
            }
        }
        if let id = message.toolCallID { wire["tool_call_id"] = id }
        if !message.toolCalls.isEmpty {
            wire["tool_calls"] = message.toolCalls.map { call in
                ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments]]
                    as [String: Any]
            }
        }
        return wire
    }
}
