import Foundation

/// Why a reply couldn't be had (ADR-001 §4.2, §8.2), in the terms the chat shows.
public enum ChatError: Error, Equatable, Sendable {
    case offline
    /// Nothing answers on this Mac's server: Ollama isn't running.
    case serverDown(URL)
    case unreachable(host: String)
    case timeout
    /// 401/403 and no token is saved.
    case needsToken
    /// 401/403 with a token.
    case badToken
    case rateLimited(retryAfter: Duration?)
    case modelMissing(String)
    case contextTooLong
    /// The server answered with a redirect, never followed (F7).
    case redirected(host: String)
    /// Any other error status, with the server's message, secrets masked.
    case server(status: Int, message: String)
    case badResponse
    /// The keychain refused to give the endpoint's token, so nothing was sent. Try Again asks again.
    case keychainDenied
}

/// Why the model stopped.
public enum StopReason: String, Equatable, Sendable {
    case stop
    case toolCalls = "tool_calls"
    case length
    case contentFilter = "content_filter"
    case other
}

public struct Usage: Equatable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
}

/// What the provider reports as a reply streams (ADR-001 §8.1).
public enum LLMEvent: Equatable, Sendable {
    case text(String)
    /// One whole tool call, its argument pieces joined by index.
    case toolCall(id: String, name: String, arguments: Data)
    case finished(StopReason, Usage?)
}

/// Reads the `data:` events of a streamed chat completion: `delta.content`,
/// `delta.tool_calls[i]` (joined by index), `finish_reason`, the optional usage chunk, and
/// `[DONE]`. Text is reported as it comes; tool calls and `.finished` once the stream ends.
struct ChatCompletionStream {
    private var toolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
    /// Masks secrets in a server message, the token that was sent included.
    private let redact: (String) -> String
    private var stopReason: StopReason?
    private var usage: Usage?
    private(set) var isDone = false

    init(redact: @escaping (String) -> String = { redactSecrets($0) }) {
        self.redact = redact
    }

    /// The events in one SSE event. Throws `.badResponse` for data that isn't a chunk.
    mutating func read(_ event: SSEEvent) throws(ChatError) -> [LLMEvent] {
        guard !isDone else { return [] }
        if event.data == "[DONE]" { return finish() }
        guard let data = event.data.data(using: .utf8),
            let chunk = try? Self.decoder.decode(Chunk.self, from: data)
        else { throw .badResponse }
        if let error = chunk.error { throw .server(status: 200, message: redact(error.message ?? "")) }
        if let usage = chunk.usage {
            self.usage = Usage(promptTokens: usage.promptTokens ?? 0, completionTokens: usage.completionTokens ?? 0)
        }
        var events: [LLMEvent] = []
        for choice in chunk.choices ?? [] {
            if let text = choice.delta?.content, !text.isEmpty { events.append(.text(text)) }
            for call in choice.delta?.toolCalls ?? [] {
                let index = call.index ?? 0
                var current = toolCalls[index] ?? (id: "", name: "", arguments: "")
                if let id = call.id { current.id = id }
                if let name = call.function?.name { current.name += name }
                if let arguments = call.function?.arguments { current.arguments += arguments }
                toolCalls[index] = current
            }
            if let reason = choice.finishReason { stopReason = StopReason(rawValue: reason) ?? .other }
        }
        return events
    }

    /// `[DONE]`, or the body ended. A stream that never said why it stopped is broken.
    mutating func finish() -> [LLMEvent] {
        guard !isDone else { return [] }
        isDone = true
        let calls = toolCalls.sorted { $0.key < $1.key }.map { _, call in
            LLMEvent.toolCall(id: call.id, name: call.name, arguments: Data(call.arguments.utf8))
        }
        let reason = stopReason ?? (calls.isEmpty ? .stop : .toolCalls)
        return calls + [.finished(reason, usage)]
    }

    /// Whether the body ended with what a whole reply has.
    var sawEnd: Bool { stopReason != nil }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // The wire format, its snake_case names read as camelCase.
    private struct Chunk: Decodable {
        let choices: [Choice]?
        let usage: WireUsage?
        let error: WireError?
    }
    private struct Choice: Decodable {
        let delta: Delta?
        let finishReason: String?
    }
    private struct Delta: Decodable {
        let content: String?
        let toolCalls: [WireToolCall]?
    }
    private struct WireToolCall: Decodable {
        let index: Int?
        let id: String?
        let function: WireFunction?
    }
    private struct WireFunction: Decodable {
        let name: String?
        let arguments: String?
    }
    private struct WireUsage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
    }
    private struct WireError: Decodable {
        let message: String?
    }
}

/// Maps what went wrong with a request to the chat's errors (ADR-001 §8.2).
enum ChatErrorMapping {
    /// A transport failure. `url` is the endpoint's base URL.
    static func map(_ error: HTTPError, url: URL) -> ChatError {
        switch error {
        case .offline: return .offline
        case .refused:
            return EndpointURLPolicy.classify(url) == .loopback ? .serverDown(url) : .unreachable(host: url.host ?? "")
        case .unreachable(let host): return .unreachable(host: host.isEmpty ? url.host ?? "" : host)
        case .timeout: return .timeout
        case .redirected(let host): return .redirected(host: host ?? url.host ?? "")
        case .keychainDenied: return .keychainDenied
        // A chat request names its own endpoint's origin, so .tokenNotForThisOrigin means the
        // URL changed under it.
        case .notAllowed, .cancelled, .failed, .tokenNotForThisOrigin: return .unreachable(host: url.host ?? "")
        }
    }

    /// An error status, with the body the server sent. `hasToken` tells 401 apart.
    static func map(
        status: Int, body: Data, headers: [String: String], model: String, hasToken: Bool, now: Date = Date(),
        redact: (String) -> String = { redactSecrets($0) }
    ) -> ChatError {
        let message = redact(Self.message(body))
        switch status {
        case 401, 403: return hasToken ? .badToken : .needsToken
        case 404 where message.lowercased().contains("model") || message.isEmpty: return .modelMissing(model)
        case 429: return .rateLimited(retryAfter: retryAfter(headers["retry-after"], now: now))
        case 300..<400: return .redirected(host: "")
        default:
            let lowered = message.lowercased()
            if lowered.contains("context_length_exceeded") || lowered.contains("context length")
                || lowered.contains("maximum context") || lowered.contains("too many tokens")
            {
                return .contextTooLong
            }
            return .server(status: status, message: message)
        }
    }

    /// The server's own message, `error.message`, or the start of the body.
    static func message(_ body: Data) -> String {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
            let message: String?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
            let message = envelope.error?.message ?? envelope.message
        {
            return message
        }
        return String(decoding: body.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `Retry-After`: seconds, or an HTTP date.
    static func retryAfter(_ value: String?, now: Date) -> Duration? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Int(value) { return .seconds(max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return .seconds(max(0, Int(date.timeIntervalSince(now).rounded(.up))))
    }
}
