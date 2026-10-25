import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// What an endpoint URL is allowed to do (ADR-001 §6.1, threat model F9).
///
/// - `.loopback`: plain http to this Mac. The host must be written exactly `localhost`, a
///   dotted `127.x.x.x`, or `[::1]`, so `localhost.evil.com`, `127.0.0.1.nip.io`, `0.0.0.0`,
///   `[::ffff:127.0.0.1]`, `2130706433` and `localhost.` are not loopback.
/// - `.privateHTTP`: plain http to a private address (RFC 1918, 169.254/16, fc00::/7, or a
///   `*.local` name). Allowed with a warning, and a token is never stored or sent.
/// - `.https`: any host over https.
/// - `.rejected`: anything else: other http, other schemes, a user or password in the URL, no host.
public enum EndpointURLPolicy: Equatable, Sendable {
    case loopback
    case privateHTTP
    case https
    case rejected

    /// Whether a token may be stored for, and sent to, a URL of this kind.
    public var allowsToken: Bool { self == .https || self == .loopback }

    public static func classify(_ text: String) -> EndpointURLPolicy {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
            let scheme = parts.scheme?.lowercased(), parts.user == nil, parts.password == nil,
            let rawHost = parts.host, !rawHost.isEmpty
        else { return .rejected }
        switch scheme {
        case "https": return .https
        case "http": return classifyPlainHost(rawHost)
        default: return .rejected
        }
    }

    public static func classify(_ url: URL) -> EndpointURLPolicy { classify(url.absoluteString) }

    // MARK: Hosts over plain http

    private static func classifyPlainHost(_ rawHost: String) -> EndpointURLPolicy {
        let host = rawHost.lowercased()
        if host == "localhost" { return .loopback }
        if let octets = dottedQuad(host) {
            switch (octets[0], octets[1]) {
            case (127, _): return .loopback
            case (10, _), (172, 16...31), (192, 168), (169, 254): return .privateHTTP
            default: return .rejected
            }
        }
        if host.hasPrefix("[") || host.contains(":") {
            let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if bare == "::1" { return .loopback }
            guard let bytes = ipv6(bare) else { return .rejected }
            // fc00::/7: unique local addresses.
            return bytes[0] & 0xFE == 0xFC ? .privateHTTP : .rejected
        }
        if isLocalName(host) { return .privateHTTP }
        return .rejected
    }

    /// Four plain decimal numbers from 0 to 255, with no leading zeros: "192.168.1.20".
    static func dottedQuad(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                part.count == 1 || part.first != "0", let value = Int(part), value <= 255
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func ipv6(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    /// "nas.local", "studio-mini.local": labels of letters, digits and dashes, then `.local`.
    private static func isLocalName(_ host: String) -> Bool {
        guard host.hasSuffix(".local") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).dropLast()
        return !labels.isEmpty
            && labels.allSatisfy { label in
                !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                    && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }
    }
}
