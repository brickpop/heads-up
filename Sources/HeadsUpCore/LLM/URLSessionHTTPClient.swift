import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The real `HTTPClient` (ADR-001 §7.1): an ephemeral URLSession with no cache, cookies or
/// saved credentials, that never follows a redirect (F7). The response head comes back as soon
/// as it arrives; the body streams after it. Cancelling the task, or dropping the body, cancels
/// the request.
public final class URLSessionHTTPClient: NSObject, HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    /// The requests in flight, by task id: the waiting caller, then the body's stream.
    private var inFlight: [Int: InFlight] = [:]
    private var session: URLSession!

    private struct InFlight {
        var head: CheckedContinuation<HTTPResponse, Error>?
        let body: AsyncThrowingStream<[UInt8], Error>
        let bodyContinuation: AsyncThrowingStream<[UInt8], Error>.Continuation
    }

    public override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: Delegate(owner: self), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let task = session.dataTask(with: request)
        let id = task.taskIdentifier
        let (body, bodyContinuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        bodyContinuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { head in
                lock.withLock {
                    inFlight[id] = InFlight(head: head, body: body, bodyContinuation: bodyContinuation)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: The session's events

    fileprivate func received(response: URLResponse, task id: Int) {
        let head = lock.withLock { () -> (CheckedContinuation<HTTPResponse, Error>, HTTPResponse)? in
            guard let state = inFlight[id], let head = state.head else { return nil }
            inFlight[id]?.head = nil
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (name, value) in http?.allHeaderFields ?? [:] {
                if let name = name as? String, let value = value as? String { headers[name] = value }
            }
            return (head, HTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: state.body))
        }
        if let (continuation, response) = head { continuation.resume(returning: response) }
    }

    fileprivate func received(data: Data, task id: Int) {
        let body = lock.withLock { inFlight[id]?.bodyContinuation }
        body?.yield(Array(data))
    }

    fileprivate func completed(task id: Int, error: Error?) {
        guard let state = lock.withLock({ inFlight.removeValue(forKey: id) }) else { return }
        let mapped = error.map(Self.map)
        if let head = state.head {
            // No response arrived at all.
            head.resume(throwing: mapped ?? HTTPError.failed("no response"))
            state.bodyContinuation.finish()
        } else if let mapped {
            state.bodyContinuation.finish(throwing: mapped)
        } else {
            state.bodyContinuation.finish()
        }
    }

    /// URLSession's errors in HeadsUp's terms.
    static func map(_ error: Error) -> HTTPError {
        guard let error = error as? URLError else { return .failed("\(error)") }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .cannotConnectToHost: return .refused
        case .cannotFindHost, .dnsLookupFailed: return .unreachable(host: error.failingURL?.host ?? "")
        case .timedOut: return .timeout
        case .cancelled: return .cancelled
        default: return .failed(error.localizedDescription)
        }
    }

    /// The session holds its delegate strongly; this one holds the client weakly, so the
    /// client can go away and invalidate the session.
    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: URLSessionHTTPClient?

        init(owner: URLSessionHTTPClient) {
            self.owner = owner
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            // Never follow: the 3xx itself comes back to HTTPTransport (F7).
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            owner?.received(response: response, task: dataTask.taskIdentifier)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner?.received(data: data, task: dataTask.taskIdentifier)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            owner?.completed(task: task.taskIdentifier, error: error)
        }
    }
}
