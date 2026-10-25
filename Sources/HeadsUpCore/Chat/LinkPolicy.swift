import Foundation

/// Model or tool text made safe for the app's own UI (ADR-001 §8.5, F16): card fields, tool
/// rows, link text, list names. Control characters and direction overrides go, line breaks and
/// tabs become spaces, zero-width characters go, and the text is cut to `max` characters, ending
/// with "…".
public func sanitizeForDisplay(_ text: String, max: Int) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D: scalars.append(" ")
        // C0 and DEL, C1, the marks and overrides that change direction, their isolates, and
        // the zero-width characters that can hide inside a name (Rev 3).
        case 0x00...0x1F, 0x7F, 0x80...0x9F, 0x200B...0x200F, 0x202A...0x202E, 0x2060, 0x2066...0x2069, 0x061C,
            0xFEFF:
            continue
        default: scalars.append(scalar)
        }
    }
    let clean = String(scalars)
    guard max > 0, clean.count > max else { return clean }
    return String(clean.prefix(max - 1)) + "…"
}

/// Which links a reply may hold, how each shows where it goes, and which ask before opening
/// (ADR-001 §8.5, threat model F2; UX addendum 3).
public enum LinkPolicy {
    /// Only these open; any other scheme is shown as plain text.
    static let schemes: Set<String> = ["http", "https", "mailto"]
    /// A longer URL asks before opening.
    static let longURL = 100

    /// The URL, if it is one a link may open: http, https or mailto, and for the web a plain
    /// host (`isPlain`), so what is shown is what opens. Anything else is shown as text.
    public static func url(_ destination: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard let scheme = trimmed.split(separator: ":", maxSplits: 1).first?.lowercased(), schemes.contains(scheme),
            let url = URL(string: trimmed)
                ?? URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
        else { return nil }
        if scheme != "mailto" {
            guard let host = host(trimmed), isPlain(host) else { return nil }
        }
        return url
    }

    /// What is shown after the link text, in --ink-2: the host in punycode without `www.`, or
    /// the address of a mailto link. Nil when the link text already is the URL, unless the host
    /// has non-ASCII letters: then the punycode always shows, so a look-alike can't pass (F2).
    public static func hostLabel(_ destination: String, text: String) -> String? {
        let plainText = text.trimmingCharacters(in: .whitespaces)
        if let host = host(destination), !host.unicodeScalars.allSatisfy(\.isASCII) {
            return displayHost(host)
        }
        if plainText == destination || plainText == destination.replacingOccurrences(of: "mailto:", with: "") {
            return nil
        }
        if destination.lowercased().hasPrefix("mailto:") {
            let address = destination.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
            return address.removingPercentEncoding ?? address
        }
        return host(destination).map(displayHost)
    }

    /// Whether opening asks first: a long URL, one with a query or fragment, or one whose host
    /// isn't in any of the user's messages in this chat.
    public static func asksFirst(_ destination: String, userMessages: [String]) -> Bool {
        if destination.count > longURL || destination.contains("?") || destination.contains("#") { return true }
        if destination.lowercased().hasPrefix("mailto:") { return false }
        guard let host = host(destination), host.unicodeScalars.allSatisfy(\.isASCII) else { return true }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let forms = Set([bare, displayHost(host)])
        return !userMessages.contains { message in
            let lowered = message.lowercased()
            return forms.contains { containsWhole($0, in: lowered) }
        }
    }

    /// Whether the URL opens the host that is shown: what `URL` parsed must be the host read
    /// from the text, both without `www.` or a trailing dot. A link where they differ asks first.
    public static func opensShownHost(_ destination: String) -> Bool {
        guard !destination.lowercased().hasPrefix("mailto:") else { return true }
        guard let shown = host(destination), let url = url(destination), let opened = url.host else { return false }
        return normalized(displayHost(opened.lowercased())) == normalized(displayHost(shown))
    }

    private static func normalized(_ host: String) -> String {
        var host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// A host that is only letters, digits, dots and dashes once in punycode, or a bracketed
    /// IPv6 address: no backslash, space or control character a browser would read otherwise.
    static func isPlain(_ host: String) -> Bool {
        if host.hasPrefix("[") {
            return host.hasSuffix("]")
                && host.dropFirst().dropLast().allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        return displayHost(host).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    /// Whether `host` is in `text` as a whole name: not the end of a longer one
    /// ("s.swift.org" in "docs.swift.org") nor the start ("swift.or" in "swift.org").
    private static func containsWhole(_ host: String, in text: String) -> Bool {
        func isNamePart(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.isLetter || character.isNumber || character == "-" || character == "."
        }
        var searchStart = text.startIndex
        while let found = text.range(of: host, range: searchStart..<text.endIndex) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            var after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            // A full stop that ends the sentence isn't part of the name.
            if after == ".",
                text.index(after: found.upperBound) == text.endIndex
                    || !isNamePart(text[text.index(after: found.upperBound)])
            {
                after = nil
            }
            if !isNamePart(before) && !isNamePart(after) { return true }
            searchStart = text.index(after: found.lowerBound)
        }
        return false
    }

    /// The host of an http(s) URL, lower case, from the text itself: so a non-ASCII host is
    /// read as written, before any library rewrites it.
    static func host(_ destination: String) -> String? {
        guard let schemeEnd = destination.range(of: "://") else { return nil }
        var rest = destination[schemeEnd.upperBound...]
        if let end = rest.firstIndex(where: { "/?#".contains($0) }) { rest = rest[..<end] }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        var host = String(rest)
        if host.hasPrefix("[") {
            host = host.split(separator: "]").first.map { $0 + "]" } ?? host
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        host = (host.removingPercentEncoding ?? host).lowercased()
        return host.isEmpty ? nil : host
    }

    /// "evil.example", "xn--bcher-kva.de": no `www.`, and non-ASCII labels in punycode, so
    /// look-alike letters can't hide the real host.
    static func displayHost(_ host: String) -> String {
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return bare.split(separator: ".", omittingEmptySubsequences: false).map { label in
            label.unicodeScalars.allSatisfy(\.isASCII)
                ? String(label) : "xn--" + Punycode.encode(String(label).precomposedStringWithCanonicalMapping)
        }.joined(separator: ".")
    }
}

/// Punycode (RFC 3492): how a non-ASCII domain label is written in ASCII.
enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700, initialBias = 72, initialN = 128

    static func encode(_ label: String) -> String {
        let input = label.unicodeScalars.map { Int($0.value) }
        var output = input.filter { $0 < 0x80 }.map { Character(Unicode.Scalar(UInt8($0))) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }
        var n = initialN
        var delta = 0
        var bias = initialBias
        while handled < input.count {
            let next = input.filter { $0 >= n }.min() ?? n
            delta += (next - n) * (handled + 1)
            n = next
            for code in input {
                if code < n { delta += 1 }
                guard code == n else { continue }
                var q = delta
                var k = base
                while true {
                    let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                    if q < t { break }
                    output.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q))
                bias = adapt(delta, handled + 1, handled == basicCount)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    private static func digit(_ value: Int) -> Character {
        Character(Unicode.Scalar(UInt8(value < 26 ? value + 97 : value + 22)))
    }

    private static func adapt(_ delta: Int, _ count: Int, _ first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / count
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }
}
