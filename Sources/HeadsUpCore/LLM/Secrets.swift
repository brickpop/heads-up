import Foundation

/// Endpoint tokens (ADR-001 §6.4): in the login keychain on macOS, a generic password per
/// endpoint, never synced. The item's access list lets only HeadsUp read it without a prompt,
/// and the keychain is locked while the user is logged out; the token isn't bound to this Mac.
/// The mask is kept beside it, so listing endpoints never reads a token or prompts.
public protocol SecretStore: Sendable {
    /// The token, read for one request. Nil when none is saved; throws when the keychain
    /// refuses the read (the user denied it, or it is locked).
    func token(for endpointID: String) throws(SecretStoreError) -> String?
    /// Saves the token and its mask, replacing any saved one.
    func setToken(_ token: String, for endpointID: String) throws(SecretStoreError)
    /// Removes the token; nothing happens when none is saved.
    func removeToken(for endpointID: String) throws(SecretStoreError)
    /// "sk-…a91f", without reading the token.
    func mask(for endpointID: String) -> String?
}

/// The Keychain refused, with its status, for the log; the UI says it in plain words.
public struct SecretStoreError: Error, Equatable, Sendable {
    public let status: Int32

    public init(status: Int32) {
        self.status = status
    }
}

/// How a saved token is shown (ADR-001 §6.4, F18): at most 3 leading and 4 trailing
/// characters, "sk-…a91f". A short token shows nothing of itself.
public enum TokenMask {
    public static func make(_ token: String) -> String {
        guard token.count >= 12 else { return "••••" }
        return "\(token.prefix(3))…\(token.suffix(4))"
    }
}

/// Error details with secrets masked (ADR-001 §6.4, F7): `Authorization` values, Bearer
/// tokens, `sk-…`-style keys, and any token HeadsUp knows, each become "••••".
public func redactSecrets(_ text: String, known: [String] = []) -> String {
    var result = text
    for token in known where token.count >= 4 {
        result = result.replacingOccurrences(of: token, with: "••••")
    }
    let patterns: [(String, String)] = [
        (#"(?i)(authorization["']?\s*[:=]\s*["']?)(bearer\s+)?[^\s"',}]+"#, "$1$2••••"),
        (#"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{4,}"#, "$1••••"),
        (#"\b(sk|pk|rk)-[A-Za-z0-9_-]{6,}"#, "••••"),
    ]
    for (pattern, template) in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        result = regex.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
    }
    return result
}

#if DEBUG
    /// Tokens in memory, for tests and previews.
    public final class MemorySecretStore: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [String: String] = [:]
        /// Set to make every call fail with this status.
        public var failure: Int32? {
            get { lock.withLock { failureStatus } }
            set { lock.withLock { failureStatus = newValue } }
        }
        private var failureStatus: Int32?

        public init(_ tokens: [String: String] = [:]) {
            self.tokens = tokens
        }

        public func token(for endpointID: String) throws(SecretStoreError) -> String? {
            lock.lock()
            defer { lock.unlock() }
            if let failureStatus { throw SecretStoreError(status: failureStatus) }
            return tokens[endpointID]
        }

        public func setToken(_ token: String, for endpointID: String) throws(SecretStoreError) {
            lock.lock()
            defer { lock.unlock() }
            if let failureStatus { throw SecretStoreError(status: failureStatus) }
            tokens[endpointID] = token
        }

        public func removeToken(for endpointID: String) throws(SecretStoreError) {
            lock.lock()
            defer { lock.unlock() }
            if let failureStatus { throw SecretStoreError(status: failureStatus) }
            tokens[endpointID] = nil
        }

        public func mask(for endpointID: String) -> String? {
            lock.withLock { tokens[endpointID].map(TokenMask.make) }
        }

        /// What is saved, for tests.
        public var saved: [String: String] { lock.withLock { tokens } }
    }
#endif
