import Foundation

/// Parses a reply as it streams in, so each 30 Hz redraw costs the new text, not the whole
/// reply: a 32 KB reply takes tens of milliseconds to parse whole.
///
/// The text up to the last blank line outside fenced code is parsed once and kept; only what
/// follows it is parsed again at each redraw. A blank line can split a block the whole text
/// would join, such as a list that continues after it, so a finished reply is parsed whole once.
struct ReplyParser {
    /// The text parsed for good, which ends at a blank line outside fenced code.
    private var stableText = ""
    private var stableBlocks: [Block] = []

    mutating func blocks(_ text: String) -> [Block] {
        if !text.hasPrefix(stableText) {
            stableText = ""
            stableBlocks = []
        }
        let rest = text.dropFirst(stableText.count)
        if let boundary = Self.lastBoundary(in: rest) {
            let segment = rest[..<boundary]
            stableBlocks += MarkdownBlocks.parse(String(segment))
            stableText += segment
        }
        return stableBlocks + MarkdownBlocks.parse(String(text.dropFirst(stableText.count)))
    }

    /// The end of the last blank line in `text` that isn't inside fenced code. `text` starts at
    /// a line start, outside any fence.
    static func lastBoundary(in text: Substring) -> Substring.Index? {
        var inFence = false
        var boundary: Substring.Index?
        var lineStart = text.startIndex
        var previousBlank = false
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            guard lineEnd < text.endIndex else { break }  // the last line hasn't ended yet
            let line = text[lineStart..<lineEnd]
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            let blank = line.allSatisfy { $0 == " " || $0 == "\t" }
            let next = text.index(after: lineEnd)
            if blank && !inFence && !previousBlank { boundary = next }
            previousBlank = blank
            lineStart = next
        }
        return boundary
    }
}
