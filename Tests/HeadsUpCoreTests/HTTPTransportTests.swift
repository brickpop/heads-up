import Foundation
import Testing

@testable import HeadsUpCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Records each request and answers with a fixed status and body.
private final class RecordingClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    let status: Int
    let headers: [String: String]

    init(status: Int = 200, headers: [String: String] = [:]) {
        self.status = status
        self.headers = headers
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        let (body, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        continuation.yield(Array("ok".utf8))
        continuation.finish()
        return HTTPResponse(status: status, headers: headers, body: body)
    }
}

@Suite struct HTTPTransportTests {
    private let secrets = MemorySecretStore(["ep": "sk-proj-saved-token-1234"])

    private func send(_ url: String, credential: Credential?, headers: [String: String] = [:]) async throws
        -> URLRequest?
    {
        let client = RecordingClient()
        let transport = HTTPTransport(client: client, secrets: secrets)
        _ = try? await transport.send(HTTPRequest(url: URL(string: url)!, headers: headers, credential: credential))
        return client.requests.first
    }

    @Test func theSavedTokenGoesOnlyWhereThePolicyAllows() async throws {
        let https = try await send(
            "https://api.openai.com/v1/models",
            credential: .saved(endpointID: "ep", origin: Origin("https://api.openai.com")!))
        #expect(https?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-proj-saved-token-1234")
        let loopback = try await send(
            "http://localhost:11434/v1/models",
            credential: .saved(endpointID: "ep", origin: Origin("http://localhost:11434")!))
        #expect(loopback?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-proj-saved-token-1234")
    }

    // S3: Test connection on a .privateHTTP URL sends no Authorization, saved or typed.
    @Test func aPrivateHTTPURLNeverGetsAToken() async throws {
        for credential in [
            Credential.saved(endpointID: "ep", origin: Origin("http://192.168.1.20:11434")!),
            .typed("sk-typed-in-the-form"),
        ] {
            let request = try await send("http://192.168.1.20:11434/v1/models", credential: credential)
            #expect(request != nil)
            #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test func aRejectedURLIsNeverSent() async throws {
        let client = RecordingClient()
        let transport = HTTPTransport(client: client, secrets: secrets)
        await #expect(throws: HTTPError.notAllowed) {
            _ = try await transport.send(
                HTTPRequest(
                    url: URL(string: "http://api.openai.com/v1")!,
                    credential: .saved(endpointID: "ep", origin: Origin("http://api.openai.com")!)))
        }
        #expect(client.requests.isEmpty)
    }

    @Test func aCallerCantSetAuthorizationItself() async throws {
        let request = try await send(
            "https://api.example.com/v1", credential: nil, headers: ["authorization": "Bearer smuggled", "X-A": "1"])
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request?.value(forHTTPHeaderField: "X-A") == "1")
    }

    @Test func aTokenThatCouldAddAHeaderIsNeverSent() async throws {
        let request = try await send("https://api.example.com/v1", credential: .typed("abc\r\nX-Evil: 1"))
        #expect(request?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aRedirectComesBackAsAnErrorWithItsHost() async throws {
        let client = RecordingClient(status: 307, headers: ["Location": "https://evil.example/steal"])
        let transport = HTTPTransport(client: client, secrets: secrets)
        await #expect(throws: HTTPError.redirected(host: "evil.example")) {
            _ = try await transport.send(
                HTTPRequest(
                    url: URL(string: "https://api.openai.com/v1/models")!,
                    credential: .saved(endpointID: "ep", origin: Origin("https://api.openai.com")!))
            )
        }
        #expect(client.requests.count == 1)
    }
}

/// A tiny HTTP/1.1 server on 127.0.0.1, for the real URLSession client: it records each
/// request's head and answers with `respond`, written in the pieces it returns.
private final class LocalServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var heads: [String] = []
    private let respond: @Sendable (String) -> [String]

    init(respond: @escaping @Sendable (String) -> [String]) throws {
        self.respond = respond
        #if canImport(Glibc)
            fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
            fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fd = self.fd
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard ok else { throw HTTPError.failed("listen") }
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in serve() }
    }

    var requests: [String] { lock.withLock { heads } }

    func stop() {
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
    }

    private func serve() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var head = [UInt8]()
            var byte: UInt8 = 0
            while read(client, &byte, 1) == 1 {
                head.append(byte)
                if head.suffix(4) == [13, 10, 13, 10] { break }
            }
            let text = String(decoding: head, as: UTF8.self)
            lock.withLock { heads.append(text) }
            for piece in respond(text) {
                _ = piece.utf8CString.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count - 1) }
                usleep(20_000)
            }
            close(client)
        }
    }
}

@Suite(.serialized) struct URLSessionHTTPClientTests {
    // F7: a 307 to another host comes back as .redirected, and nothing reaches that host.
    @Test func aRedirectIsNeverFollowedAndTheTokenGoesNowhereElse() async throws {
        let other = try LocalServer { _ in ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"] }
        defer { other.stop() }
        let first = try LocalServer { _ in
            [
                "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(other.port)/steal\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            ]
        }
        defer { first.stop() }
        let transport = HTTPTransport(
            client: URLSessionHTTPClient(), secrets: MemorySecretStore(["ep": "sk-proj-saved-token-1234"]))
        await #expect(throws: HTTPError.redirected(host: "127.0.0.1")) {
            _ = try await transport.send(
                HTTPRequest(
                    url: URL(string: "http://127.0.0.1:\(first.port)/v1/models")!,
                    credential: .saved(endpointID: "ep", origin: Origin("http://127.0.0.1:\(first.port)")!),
                    timeout: 5))
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(first.requests.count == 1)
        #expect(first.requests.first?.lowercased().contains("authorization: bearer sk-proj-saved-token-1234") == true)
        #expect(other.requests.isEmpty)
    }

    @Test func theBodyStreamsAsItArrives() async throws {
        let server = try LocalServer { _ in
            [
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
                "data: one\n\n", "data: two\n\n",
            ]
        }
        defer { server.stop() }
        let client = URLSessionHTTPClient()
        let response = try await client.send(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!))
        #expect(response.status == 200)
        #expect(response.headers["content-type"] == "text/event-stream")
        var parser = SSEParser()
        var events: [String] = []
        for try await chunk in response.body { events += try parser.feed(chunk).map(\.data) }
        #expect(events == ["one", "two"])
    }

    @Test func nothingListeningIsRefused() async throws {
        let server = try LocalServer { _ in [] }
        let port = server.port
        server.stop()
        await #expect(throws: HTTPError.refused) {
            _ = try await URLSessionHTTPClient().send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        }
    }

    @Test func noCookieIsKeptOrSent() async throws {
        let server = try LocalServer { _ in
            ["HTTP/1.1 200 OK\r\nSet-Cookie: session=abc\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"]
        }
        defer { server.stop() }
        let client = URLSessionHTTPClient()
        let url = URL(string: "http://127.0.0.1:\(server.port)/")!
        _ = try await client.send(URLRequest(url: url)).collect()
        _ = try await client.send(URLRequest(url: url)).collect()
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { !$0.lowercased().contains("cookie:") })
    }
}

/// Answers every request with one scripted response, its body in the given pieces, or fails.
private final class ScriptedClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    let status: Int
    let pieces: [String]
    let failure: HTTPError?

    init(status: Int = 200, pieces: [String] = [], failure: HTTPError? = nil) {
        self.status = status
        self.pieces = pieces
        self.failure = failure
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        if let failure { throw failure }
        let (body, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        for piece in pieces { continuation.yield(Array(piece.utf8)) }
        continuation.finish()
        return HTTPResponse(status: status, headers: ["Content-Type": "text/event-stream"], body: body)
    }
}

@Suite struct OpenAICompatibleProviderTests {
    private let cloud = Endpoint(
        id: "ep", name: "GPT-4o mini", baseURL: "https://api.openai.com/v1/", model: "gpt-4o-mini", images: true,
        hasToken: true)
    private let secrets = MemorySecretStore(["ep": "sk-proj-saved-token-1234"])

    private func run(_ client: ScriptedClient, endpoint: Endpoint? = nil, tools: [LLMTool] = []) async
        -> (events: [LLMEvent], error: Error?)
    {
        let provider = OpenAICompatibleProvider(transport: HTTPTransport(client: client, secrets: secrets))
        var events: [LLMEvent] = []
        do {
            for try await event in provider.stream(
                endpoint: endpoint ?? cloud,
                messages: [
                    .text(.system, "Be brief."),
                    LLMMessage(
                        role: .user, parts: [.text("What's this?"), .imageDataURL("data:image/png;base64,AAAA")]),
                ], tools: tools)
            {
                events.append(event)
            }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    @Test func itPostsAStreamingRequestAndTheTransportAddsTheToken() async throws {
        let client = ScriptedClient(pieces: [
            #"data: {"choices":[{"delta":{"content":"A cat"},"finish_reason":"stop"}]}"# + "\n\n", "data: [DONE]\n\n",
        ])
        let tool = LLMTool(
            name: "clipboard_read", description: "Reads the clipboard", parameters: Data(#"{"type":"object"}"#.utf8))
        let (events, error) = await run(client, tools: [tool])
        #expect(error == nil)
        #expect(events == [.text("A cat"), .finished(.stop, nil)])
        let request = try #require(client.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-proj-saved-token-1234")
        let body = try #require(
            request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["model"] as? String == "gpt-4o-mini" && body["stream"] as? Bool == true)
        #expect((body["stream_options"] as? [String: Bool])?["include_usage"] == true)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == "Be brief.")
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(parts[0]["type"] as? String == "text" && parts[1]["type"] as? String == "image_url")
        #expect((body["tools"] as? [[String: Any]])?.first?["type"] as? String == "function")
    }

    @Test func noToolsAreSentToAModelThatCantUseThem() async throws {
        var endpoint = cloud
        endpoint.tools = false
        let client = ScriptedClient(pieces: ["data: [DONE]\n\n"])
        let tool = LLMTool(name: "x", description: "", parameters: Data("{}".utf8))
        _ = await run(client, endpoint: endpoint, tools: [tool])
        let body = try #require(
            client.requests.first?.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["tools"] == nil)
    }

    @Test func errorsInTheChatsTerms() async throws {
        var noToken = cloud
        noToken.hasToken = false
        #expect(await run(ScriptedClient(status: 401), endpoint: noToken).error as? ChatError == .needsToken)
        #expect(await run(ScriptedClient(status: 401)).error as? ChatError == .badToken)
        let ollama = Endpoint(id: "o", name: "Llama", baseURL: "http://localhost:11434/v1", model: "llama3.1:8b")
        #expect(
            await run(ScriptedClient(failure: .refused), endpoint: ollama).error as? ChatError
                == .serverDown(URL(string: "http://localhost:11434/v1")!))
        #expect(
            await run(ScriptedClient(status: 307)).error as? ChatError == .redirected(host: "api.openai.com"))
    }

    @Test func aBodyThatEndsMidReplyIsABadResponse() async throws {
        let (events, error) = await run(
            ScriptedClient(pieces: [#"data: {"choices":[{"delta":{"content":"Half"}}]}"# + "\n\n"]))
        #expect(events == [.text("Half")])
        #expect(error as? ChatError == .badResponse)
    }
}
