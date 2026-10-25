import Foundation

/// One server-sent event.
public struct SSEEvent: Equatable, Sendable {
    /// The `event:` field; nil for the default "message".
    public var event: String?
    /// The `data:` lines, joined with "\n".
    public var data: String
}

/// Reads a `text/event-stream` body as it arrives (the WHATWG rules the OpenAI-compatible
/// servers follow). Bytes come in chunks that may cut a line, a line ending or a character in
/// two; a line is read once it ends, and an event is ready at the blank line after it.
public struct SSEParser: Sendable {
    /// A line or an event past the limits: a server sending endless data is broken (Scan L2).
    public struct TooLong: Error, Equatable {}

    static let maxLine = 1 << 20
    static let maxEvent = 4 << 20

    private var pending: [UInt8] = []
    /// A "\r" ended the last chunk: a "\n" at the start of the next one belongs to it.
    private var afterCarriageReturn = false
    private var event: String?
    private var dataLines: [String] = []
    private var atStart = true
    /// Bytes of data in the event being read.
    private var eventSize = 0

    public init() {}

    /// Adds bytes and returns the events they complete. Throws past 1 MB in a line or 4 MB
    /// in an event.
    public mutating func feed(_ bytes: some Sequence<UInt8>) throws(TooLong) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            if afterCarriageReturn {
                afterCarriageReturn = false
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0A:
                if let event = try line() { events.append(event) }
            case 0x0D:
                if let event = try line() { events.append(event) }
                afterCarriageReturn = true
            default:
                pending.append(byte)
                if pending.count > Self.maxLine { throw TooLong() }
            }
        }
        return events
    }

    /// The stream ended: an event without its blank line is dropped, as the standard says.
    public mutating func finish() -> [SSEEvent] {
        pending = []
        dataLines = []
        event = nil
        eventSize = 0
        return []
    }

    /// Handles the line in `pending`; returns an event at a blank line.
    private mutating func line() throws(TooLong) -> SSEEvent? {
        var bytes = pending
        pending = []
        if atStart {
            atStart = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }
        guard !bytes.isEmpty else { return dispatch() }
        let text = String(decoding: bytes, as: UTF8.self)
        if text.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "data":
            dataLines.append(String(value))
            eventSize += value.utf8.count + 1
            if eventSize > Self.maxEvent { throw TooLong() }
        case "event": event = String(value)
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            dataLines = []
            event = nil
            eventSize = 0
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: event, data: dataLines.joined(separator: "\n"))
    }
}
