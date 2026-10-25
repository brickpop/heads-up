import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Where the token for a request comes from. Only `HTTPTransport` turns it into a header.
public enum Credential: Equatable, Sendable {
    /// The token saved in the Keychain for this endpoint, read for this request. It goes only
    /// to `origin`, the scheme, host and port it was saved for (F7).
    case saved(endpointID: String, origin: Origin)
    /// A token typed in the endpoint form and not saved yet: Test connection on a draft.
    case typed(String)
}

/// The scheme, host and port a token belongs to: "https://api.openai.com:443".
public struct Origin: Hashable, Sendable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(_ url: String) {
        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
            let host = parts.host?.lowercased(), !host.isEmpty
        else { return nil }
        self.scheme = scheme
        self.host = host
        port = parts.port ?? (scheme == "https" ? 443 : 80)
    }

    public init?(_ url: URL) { self.init(url.absoluteString) }

    public var description: String { "\(scheme)://\(host):\(port)" }
}

/// A request to a model server, before the transport adds the token.
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    /// Any `Authorization` header set here is dropped: the transport alone adds it (S3).
    public var headers: [String: String]
    public var body: Data?
    public var credential: Credential?
    /// How long the server may stay silent before the request fails.
    public var timeout: TimeInterval

    public init(
        method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil,
        credential: Credential? = nil, timeout: TimeInterval = 60
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.credential = credential
        self.timeout = timeout
    }
}

/// A response whose body arrives as it comes.
public struct HTTPResponse: Sendable {
    public let status: Int
    /// Header names in lower case.
    public let headers: [String: String]
    public let body: AsyncThrowingStream<[UInt8], Error>
    /// The token the transport sent with the request, so error details can mask it.
    private let attachedToken: String?

    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<[UInt8], Error>) {
        self.init(status: status, headers: headers, body: body, attachedToken: nil)
    }

    private init(
        status: Int, headers: [String: String], body: AsyncThrowingStream<[UInt8], Error>, attachedToken: String?
    ) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        self.body = body
        self.attachedToken = attachedToken
    }

    /// The same response, knowing the token that was sent.
    func attaching(_ token: String?) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: body, attachedToken: token)
    }

    /// Server text with secrets masked, the token that was sent included (F7 c).
    public func redact(_ text: String) -> String {
        redactSecrets(text, known: attachedToken.map { [$0] } ?? [])
    }

    /// The whole body, up to `limit` bytes.
    public func collect(limit: Int = 1 << 20) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(contentsOf: chunk.prefix(max(0, limit - data.count)))
            if data.count >= limit { break }
        }
        return data
    }
}

/// Why a request got no usable response.
public enum HTTPError: Error, Equatable, Sendable {
    /// The URL policy refuses this URL (F9).
    case notAllowed
    /// The server answered with a redirect, which is never followed, so the token never goes
    /// to another host (F7).
    case redirected(host: String?)
    case offline
    /// Nothing listens on that host and port.
    case refused
    case unreachable(host: String)
    case timeout
    case cancelled
    case failed(String)
    /// The keychain refused to give the saved token (the user denied it, or it is locked), so
    /// nothing was sent. Asked again only after `HTTPTransport.allowKeychainRead`.
    case keychainDenied
    /// A saved token was named for a request to another origin: nothing was sent (F7).
    case tokenNotForThisOrigin
}

/// Sends a `URLRequest` exactly as given, never following a redirect. `URLSessionHTTPClient`
/// is the real one; tests use a fake or a local server.
public protocol HTTPClient: Sendable {
    /// Throws `HTTPError`.
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// Every request to a model server goes through here (ADR-001 §7.1). It is the only code that
/// adds `Authorization` (S3): for each request it asks `EndpointURLPolicy` whether a token may
/// go to that URL, and the `SecretStore` for the token. A redirect comes back as
/// `.redirected`, its body unread (F7).
public final class HTTPTransport: @unchecked Sendable {
    private let client: HTTPClient
    private let secrets: SecretStore
    private let lock = NSLock()
    /// Endpoints whose saved token the keychain refused to give: not asked again, so the user
    /// isn't prompted on every message, until `allowKeychainRead`.
    private var keychainDenied: Set<String> = []

    public init(client: HTTPClient, secrets: SecretStore) {
        self.client = client
        self.secrets = secrets
    }

    public func send(_ request: HTTPRequest) async throws(HTTPError) -> HTTPResponse {
        let policy = EndpointURLPolicy.classify(request.url)
        guard policy != .rejected else { throw .notAllowed }
        var outgoing = URLRequest(url: request.url, timeoutInterval: request.timeout)
        outgoing.httpMethod = request.method
        outgoing.httpBody = request.body
        for (name, value) in request.headers where name.lowercased() != "authorization" {
            outgoing.setValue(value, forHTTPHeaderField: name)
        }
        // A private address over http never reads or sends a token (F9).
        let token = policy.allowsToken ? try self.token(request.credential, for: request.url) : nil
        if let token {
            outgoing.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let response: HTTPResponse
        do {
            response = try await client.send(outgoing).attaching(token)
        } catch let error as HTTPError {
            throw error
        } catch {
            throw .failed("\(error)")
        }
        if (300..<400).contains(response.status) {
            let location = response.headers["location"].flatMap { URL(string: $0, relativeTo: request.url) }
            throw .redirected(host: location?.host ?? request.url.host)
        }
        return response
    }

    /// Try Again after the keychain refused: the next request asks it again.
    public func allowKeychainRead(_ endpointID: String) {
        _ = lock.withLock { keychainDenied.remove(endpointID) }
    }

    /// The token for this request, if there is one that can be a header value. A saved token
    /// goes only to its own origin, and a refused read sends nothing.
    private func token(_ credential: Credential?, for url: URL) throws(HTTPError) -> String? {
        let token: String?
        switch credential {
        case .saved(let id, let origin):
            guard Origin(url) == origin else { throw .tokenNotForThisOrigin }
            if lock.withLock({ keychainDenied.contains(id) }) { throw .keychainDenied }
            do {
                token = try secrets.token(for: id)
            } catch {
                lock.withLock { _ = keychainDenied.insert(id) }
                throw .keychainDenied
            }
        case .typed(let typed): token = typed
        case nil: token = nil
        }
        guard let token, Self.isUsable(token) else { return nil }
        return token
    }

    /// A token that is one line of visible ASCII, so it can't add a header of its own.
    static func isUsable(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }
}
