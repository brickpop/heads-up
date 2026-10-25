import Foundation

/// One line of a service's log, with the time it arrived.
public struct LogLine: Equatable, Sendable {
    /// Its place in the log: it rises with each line for the life of the log, and stays the
    /// same while older lines drop off the front or are cleared.
    public let id: Int
    public let time: Date
    public let text: String

    public init(id: Int = 0, time: Date, text: String) {
        self.id = id
        self.time = time
        self.text = text
    }
}

/// A service's log (ADR-001 §7.2; Services spec): stdout and stderr merged, always captured,
/// kept to the last 256 KB. Output arrives in chunks that may cut a line, or a character,
/// in two; a line is stored once it ends.
public struct LogRing: Equatable, Sendable {
    public static let defaultCapacity = 256 * 1024

    public private(set) var lines: [LogLine] = []
    /// Bytes of text held, the measure of the capacity.
    private var size = 0
    /// The start of a line that hasn't ended yet.
    private var partial = Data()
    /// The id of the next line.
    private var nextID = 0
    private let capacity: Int

    public init(capacity: Int = LogRing.defaultCapacity) {
        self.capacity = capacity
    }

    /// Adds raw output from the process.
    public mutating func append(output: Data, at time: Date) {
        partial.append(output)
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<newline]
            add(String(decoding: line, as: UTF8.self), at: time)
            partial = Data(partial[partial.index(after: newline)...])
        }
        // A line with no end, longer than the whole log, is cut here.
        if partial.count > capacity {
            add(String(decoding: partial.prefix(capacity), as: UTF8.self), at: time)
            partial = Data()
        }
    }

    /// Adds a line of HeadsUp's own: `$ npm run dev`, `starting…`, `process exited (code 1)`.
    public mutating func appendLine(_ text: String, at time: Date) {
        flush(at: time)
        add(text, at: time)
    }

    /// Stores an unfinished last line, when the process has exited.
    public mutating func flush(at time: Date) {
        guard !partial.isEmpty else { return }
        add(String(decoding: partial, as: UTF8.self), at: time)
        partial = Data()
    }

    /// Clear, from the log drawer.
    public mutating func clear() {
        lines = []
        size = 0
        partial = Data()
    }

    private mutating func add(_ text: String, at time: Date) {
        let text = text.hasSuffix("\r") ? String(text.dropLast()) : text
        lines.append(LogLine(id: nextID, time: time, text: text))
        nextID += 1
        size += text.utf8.count + 1
        var dropped = 0
        while size > capacity, dropped < lines.count {
            size -= lines[dropped].text.utf8.count + 1
            dropped += 1
        }
        if dropped > 0 { lines.removeFirst(dropped) }
    }

    /// "14:03:27  Listening on :3000"
    public static func format(_ line: LogLine, timeZone: TimeZone = .current) -> String {
        "\(time(line.time, timeZone: timeZone))  \(line.text)"
    }

    /// "14:03:27"
    public static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: timeZone, from: date)
        func two(_ value: Int?) -> String {
            let value = value ?? 0
            return value < 10 ? "0\(value)" : "\(value)"
        }
        return "\(two(parts.hour)):\(two(parts.minute)):\(two(parts.second))"
    }
}
