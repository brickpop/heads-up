import Foundation
import Testing

@testable import HeadsUpCore

/// F9: every host with its class, including the tricky ones of ADR §6.1.
@Suite struct EndpointURLPolicyTests {
    @Test func loopbackOnlyByItsCanonicalForms() {
        for url in [
            "http://localhost:11434/v1", "http://LOCALHOST:1234/v1", "http://127.0.0.1:8080", "http://127.1.2.3/v1",
            "http://[::1]:11434/v1",
        ] {
            #expect(EndpointURLPolicy.classify(url) == .loopback, "\(url)")
        }
    }

    @Test func lookAlikesOverHTTPAreRejected() {
        for url in [
            "http://localhost.evil.com/v1", "http://127.0.0.1.nip.io/v1", "http://0.0.0.0:11434",
            "http://[::ffff:127.0.0.1]/v1", "http://2130706433/v1", "http://localhost./v1", "http://127.0.0.1./v1",
            "http://127.000.000.001/v1", "http://0x7f.0.0.1/v1", "http://[0:0:0:0:0:0:0:1]/v1",
        ] {
            #expect(EndpointURLPolicy.classify(url) == .rejected, "\(url)")
        }
    }

    @Test func privateAddressesOverHTTPWarnAndTakeNoToken() {
        for url in [
            "http://192.168.1.20:11434/v1", "http://10.0.0.5/v1", "http://172.16.0.1/v1", "http://172.31.255.255/v1",
            "http://169.254.10.10/v1", "http://[fd12:3456::1]:8080/v1", "http://studio-mini.local:1234/v1",
        ] {
            #expect(EndpointURLPolicy.classify(url) == .privateHTTP, "\(url)")
        }
        #expect(!EndpointURLPolicy.privateHTTP.allowsToken)
        #expect(EndpointURLPolicy.loopback.allowsToken && EndpointURLPolicy.https.allowsToken)
    }

    @Test func everythingElseNeedsHTTPS() {
        for url in [
            "http://api.openai.com/v1", "http://172.32.0.1/v1", "http://8.8.8.8/v1", "http://.local/v1",
            "ftp://localhost/v1", "file:///etc/passwd", "http://user:pass@localhost/v1", "http:///v1", "not a url",
        ] {
            #expect(EndpointURLPolicy.classify(url) == .rejected, "\(url)")
        }
    }

    @Test func httpsIsJustHTTPSWhateverTheHost() {
        for url in [
            "https://api.openai.com/v1", "https://localhost.evil.com/v1", "https://127.0.0.1.nip.io/v1",
            "https://192.168.1.20/v1",
        ] {
            #expect(EndpointURLPolicy.classify(url) == .https, "\(url)")
        }
        #expect(EndpointURLPolicy.classify("https://alice:secret@api.example.com/v1") == .rejected)
    }
}

@Suite struct ProviderTagTests {
    @Test func theTableByURL() {
        #expect(ProviderTag(baseURL: "http://localhost:11434/v1") == .ollama)
        #expect(ProviderTag(baseURL: "http://127.0.0.1:1234/v1") == .lmStudio)
        #expect(ProviderTag(baseURL: "http://localhost:8080/v1") == .local)
        #expect(ProviderTag(baseURL: "https://api.openai.com/v1") == .custom(host: "api.openai.com"))
        // Only loopback is ever local, whatever the port.
        #expect(ProviderTag(baseURL: "http://192.168.1.20:11434/v1") == .custom(host: "192.168.1.20"))
        #expect(ProviderTag(baseURL: "https://evil.example:11434/v1") == .custom(host: "evil.example"))
        #expect(ProviderTag(baseURL: "http://localhost.evil.com:11434/v1") == .custom(host: "localhost.evil.com"))
        #expect(ProviderTag.ollama.isLocal && ProviderTag.local.isLocal && !ProviderTag.custom(host: "x").isLocal)
        #expect(ProviderTag.ollama.providerText == "Ollama" && ProviderTag.custom(host: "a.b").providerText == "a.b")
    }
}

@Suite struct SecretTextTests {
    @Test func theMaskShowsAtMostThreeAndFour() {
        #expect(TokenMask.make("sk-proj-abcdefghijklmnopa91f") == "sk-…a91f")
        #expect(TokenMask.make("short-token") == "••••")
    }

    // F7 (c): Details never show a token.
    @Test func detailsAreRedacted() {
        let detail = #"""
            {"error":{"message":"Incorrect API key provided: sk-proj-abc123XYZ789. You can find your key at …"}}
            Authorization: Bearer sk-live-abcdef123456
            authorization=Bearer abcdefghijk
            "Authorization": "Bearer tok_9f8e7d6c5b4a"
            my token is hunter22-secret
            """#
        let redacted = redactSecrets(detail, known: ["hunter22-secret"])
        #expect(!redacted.contains("sk-proj-abc123XYZ789") && !redacted.contains("sk-live-abcdef123456"))
        #expect(!redacted.contains("abcdefghijk") && !redacted.contains("tok_9f8e7d6c5b4a"))
        #expect(!redacted.contains("hunter22-secret"))
        #expect(redacted.contains("Incorrect API key provided: ••••"))
        #expect(redacted.contains("Authorization: Bearer ••••"))
    }
}

@Suite struct SSEParserTests {
    private let stream = Array(
        """
        : keep-alive\r
        data: {"a":1}\r
        \r
        event: ping\n\
        data: line one\n\
        data: line two\n\
        \n\
        data:no-space\r\r\
        data: café ☕\n\n\
        data: [DONE]\n\n
        """.utf8)

    private let expected = [
        SSEEvent(event: nil, data: #"{"a":1}"#), SSEEvent(event: "ping", data: "line one\nline two"),
        SSEEvent(event: nil, data: "no-space"), SSEEvent(event: nil, data: "café ☕"),
        SSEEvent(event: nil, data: "[DONE]"),
    ]

    @Test func readsEventsWithEveryLineEnding() throws {
        var parser = SSEParser()
        #expect(try parser.feed(stream) == expected)
    }

    // Recorded streams cut at random places: inside a line, a "\r\n" or a character.
    @Test func chunksCutAnywhereGiveTheSameEvents() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var parser = SSEParser()
            var events: [SSEEvent] = []
            var index = 0
            while index < stream.count {
                let size = Int.random(in: 1...7, using: &generator)
                events += try parser.feed(stream[index..<min(index + size, stream.count)])
                index += size
            }
            #expect(events == expected)
        }
    }

    @Test func anEventWithoutItsBlankLineIsDropped() throws {
        var parser = SSEParser()
        #expect(try parser.feed(Array("data: half".utf8)).isEmpty)
        #expect(parser.finish().isEmpty)
    }
}

/// Recorded OpenAI-compatible streams, cut at random places, through the SSE parser and the
/// chunk reader.
@Suite struct ChatCompletionStreamTests {
    private func events(_ body: String, cuts: Bool = true) throws -> [LLMEvent] {
        let bytes = Array(body.utf8)
        var parser = SSEParser()
        var stream = ChatCompletionStream()
        var events: [LLMEvent] = []
        var index = 0
        while index < bytes.count {
            let size = cuts ? Int.random(in: 1...9) : bytes.count
            for event in try parser.feed(bytes[index..<min(index + size, bytes.count)]) {
                events += try stream.read(event)
            }
            index += size
        }
        return events + stream.finish()
    }

    /// Joins the text pieces, so a test doesn't depend on how the server split them.
    private func joined(_ events: [LLMEvent]) -> [LLMEvent] {
        var result: [LLMEvent] = []
        for event in events {
            if case .text(let piece) = event, case .text(let text)? = result.last {
                result[result.count - 1] = .text(text + piece)
            } else {
                result.append(event)
            }
        }
        return result
    }

    @Test func textThenStopAndUsage() throws {
        let body = """
            data: {"id":"c1","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

            data: {"id":"c1","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

            data: {"id":"c1","choices":[{"index":0,"delta":{"content":", wörld"},"finish_reason":null}]}

            data: {"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

            data: {"id":"c1","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}

            data: [DONE]


            """
        for _ in 0..<50 {
            #expect(
                joined(try events(body))
                    == [.text("Hello, wörld"), .finished(.stop, Usage(promptTokens: 12, completionTokens: 3))])
        }
    }

    @Test func toolCallsAreJoinedByIndex() throws {
        let body = """
            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"calendar_events","arguments":""}}]}}]}

            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"clipboard_read","arguments":"{}"}}]}}]}

            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"from\\":"}}]}}]}

            data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"2026-10-25\\"}"}}]}}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]


            """
        #expect(
            try events(body) == [
                .toolCall(id: "call_a", name: "calendar_events", arguments: Data(#"{"from":"2026-10-25"}"#.utf8)),
                .toolCall(id: "call_b", name: "clipboard_read", arguments: Data("{}".utf8)),
                .finished(.toolCalls, nil),
            ])
    }

    @Test func aStreamWithoutUsageOrDoneStillFinishes() throws {
        let body = """
            data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":"length"}]}


            """
        #expect(try events(body, cuts: false) == [.text("Hi"), .finished(.length, nil)])
    }

    @Test func junkIsABadResponse() {
        var stream = ChatCompletionStream()
        #expect(throws: ChatError.badResponse) { try stream.read(SSEEvent(event: nil, data: "<html>")) }
    }

    @Test func anErrorInTheStreamIsReportedRedacted() {
        var stream = ChatCompletionStream()
        #expect(throws: ChatError.server(status: 200, message: "bad key ••••")) {
            try stream.read(SSEEvent(event: nil, data: #"{"error":{"message":"bad key sk-abcdefghij"}}"#))
        }
    }
}

@Suite struct ChatErrorMappingTests {
    private let url = URL(string: "http://localhost:11434/v1")!

    @Test func statusesInTheChatsTerms() {
        func map(_ status: Int, _ body: String = "", headers: [String: String] = [:], token: Bool = false) -> ChatError
        {
            ChatErrorMapping.map(
                status: status, body: Data(body.utf8), headers: headers, model: "llama3.1:8b", hasToken: token,
                now: Date(timeIntervalSince1970: 0))
        }
        #expect(map(401) == .needsToken && map(401, token: true) == .badToken && map(403, token: true) == .badToken)
        #expect(map(404, #"{"error":{"message":"model 'llama3.1:8b' not found"}}"#) == .modelMissing("llama3.1:8b"))
        #expect(map(429, headers: ["retry-after": "30"]) == .rateLimited(retryAfter: .seconds(30)))
        #expect(map(429) == .rateLimited(retryAfter: nil))
        #expect(
            map(429, headers: ["retry-after": "Thu, 01 Jan 1970 00:01:00 GMT"])
                == .rateLimited(retryAfter: .seconds(60)))
        #expect(
            map(
                400,
                #"{"error":{"message":"This model's maximum context length is 8192 tokens","code":"context_length_exceeded"}}"#
            )
                == .contextTooLong)
        #expect(
            map(500, #"{"error":{"message":"boom for Bearer sk-abcdef123456"}}"#)
                == .server(status: 500, message: "boom for Bearer ••••"))
    }

    @Test func transportFailuresInTheChatsTerms() {
        #expect(ChatErrorMapping.map(.refused, url: url) == .serverDown(url))
        let cloud = URL(string: "https://api.openai.com/v1")!
        #expect(ChatErrorMapping.map(.refused, url: cloud) == .unreachable(host: "api.openai.com"))
        #expect(ChatErrorMapping.map(.offline, url: cloud) == .offline)
        #expect(ChatErrorMapping.map(.timeout, url: cloud) == .timeout)
        #expect(
            ChatErrorMapping.map(.redirected(host: "evil.example"), url: cloud) == .redirected(host: "evil.example"))
    }
}
