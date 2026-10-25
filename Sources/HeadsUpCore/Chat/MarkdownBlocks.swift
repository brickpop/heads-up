import Foundation
import Markdown

/// A reply's Markdown as blocks the view draws (ADR-001 §8.5; UX part 1, §8). There is no
/// block for buttons, cards or images: a reply can't draw the app's own controls (F16).
public indirect enum Block: Equatable, Sendable {
    case heading(level: Int, [Inline])
    case paragraph([Inline])
    case list(MarkdownList)
    /// A fenced or indented block; `language` nil shows "code".
    case code(language: String?, text: String)
    case quote([Block])
    case table(MarkdownTable)
    case rule
}

public struct MarkdownList: Equatable, Sendable {
    public let ordered: Bool
    /// The first number of an ordered list, kept as written.
    public let start: Int
    public let items: [Item]

    public struct Item: Equatable, Sendable {
        /// A task list's box: nil for none, true when checked.
        public let checkbox: Bool?
        public let blocks: [Block]
    }
}

public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable {
        case leading, center, trailing
    }

    public let alignments: [Alignment]
    public let header: [[Inline]]
    public let rows: [[[Inline]]]
}

public indirect enum Inline: Equatable, Sendable {
    case text(String)
    case strong([Inline])
    case emphasis([Inline])
    case strike([Inline])
    case code(String)
    case link(LinkSpan)
    case softBreak
    case lineBreak
}

/// A link a reply may hold: http, https or mailto only (F2). Clicking it is
/// `ChatStore.openLink(destination)`.
public struct LinkSpan: Equatable, Sendable {
    public let text: [Inline]
    public let destination: String
    /// Shown after the text, in --ink-2: "evil.example". Nil when the text is the URL.
    public let hostLabel: String?
}

/// Markdown → `Block`, with swift-markdown. HTML is shown as text, an image as a link
/// "Image: alt" (nothing remote is loaded), and a link to any other scheme as plain text.
public enum MarkdownBlocks {
    /// Deeper nesting than this is shown as plain text, so hostile input can't exhaust the stack.
    static let maxDepth = 12

    /// Only this much of a reply is read as Markdown; the rest is shown as plain text.
    static let maxMarkdown = 256 * 1024
    /// swift-markdown runs on a thread with this much stack, so a deep tree that gets past the
    /// flattening still fits.
    static let parserStack = 64 << 20

    public static func parse(_ markdown: String) -> [Block] {
        let (head, tail) = split(markdown, at: maxMarkdown)
        let text = flattenRunawayNesting(head)
        let result = ParseResult()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result.blocks = Self.blocks(Document(parsing: text).children, depth: 0)
            done.signal()
        }
        thread.stackSize = parserStack
        thread.start()
        done.wait()
        var blocks = result.blocks
        if !tail.isEmpty { blocks.append(.paragraph([.text(tail)])) }
        return blocks
    }

    /// The parse's answer, handed over from its thread.
    private final class ParseResult: @unchecked Sendable {
        var blocks: [Block] = []
    }

    /// The text up to `limit` bytes, cut at a character, and the rest.
    private static func split(_ text: String, at limit: Int) -> (String, String) {
        guard text.utf8.count > limit else { return (text, "") }
        var end = text.utf8.index(text.startIndex, offsetBy: limit)
        while String.Index(end, within: text) == nil { end = text.utf8.index(before: end) }
        return (String(text[..<end]), String(text[end...]))
    }

    // MARK: Runaway nesting

    /// Most leading indentation kept on a line, in columns.
    static let maxIndent = 4 * maxDepth
    /// Longest run of `*`, `_` or `~` read as formatting.
    static let maxDelimiterRun = 2 * maxDepth

    /// Makes text that would nest thousands of levels deep shallow before swift-markdown reads
    /// it, since its tree overflows the stack on such input. Outside fenced code, on each line:
    /// indentation past `maxIndent` is cut, block markers (`>`, `-`, `1.`…) past `maxDepth`
    /// become text, and a run of `*`, `_` or `~` longer than `maxDelimiterRun` becomes text.
    /// Ordinary Markdown is left exactly as it is.
    static func flattenRunawayNesting(_ markdown: String) -> String {
        var inFence = false
        var changed = false
        // Each line, and whether it is prose: not a fence, not inside one, not blank.
        var lines: [(text: Substring, prose: Bool)] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                lines.append((line, false))
                continue
            }
            guard !inFence else {
                lines.append((line, false))
                continue
            }
            let flat = flattenLine(line)
            if flat != line { changed = true }
            lines.append((flat, !flat.allSatisfy { $0 == " " || $0 == "\t" }))
        }
        // A paragraph with many inline openers can nest deep however they are spread out: it
        // loses their formatting.
        var start = 0
        while start < lines.count {
            guard lines[start].prose else {
                start += 1
                continue
            }
            var end = start
            while end < lines.count, lines[end].prose { end += 1 }
            let openers = lines[start..<end].reduce(0) { $0 + inlineOpeners($1.text) }
            if openers > maxParagraphOpeners {
                for index in start..<end { lines[index].text = escapingInlineOpeners(lines[index].text) }
                changed = true
            }
            start = end
        }
        return changed ? lines.map(\.text).joined(separator: "\n") : markdown
    }

    /// More `*`, `_`, `~` or `[` than this in one paragraph are shown as written.
    static let maxParagraphOpeners = 200

    /// Where a line's inline text starts: after its indentation and block markers.
    private static func inlineStart(_ characters: [Character]) -> Int {
        var index = 0
        while index < characters.count {
            while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 }
            guard index < characters.count, let end = markerEnd(characters, at: index) else { break }
            index = end
        }
        return index
    }

    private static func isOpener(_ character: Character) -> Bool { "*_~[".contains(character) }

    /// The `*`, `_`, `~` and `[` in a line's inline text that aren't escaped.
    private static func inlineOpeners(_ line: Substring) -> Int {
        let characters = Array(line)
        var count = 0
        var escaped = false
        for character in characters[inlineStart(characters)...] {
            if !escaped && isOpener(character) { count += 1 }
            escaped = !escaped && character == "\\"
        }
        return count
    }

    /// The line with each of those escaped, so it reads as written.
    private static func escapingInlineOpeners(_ line: Substring) -> Substring {
        let characters = Array(line)
        let start = inlineStart(characters)
        var result = Array(characters[..<start])
        var escaped = false
        for character in characters[start...] {
            if !escaped && isOpener(character) { result.append("\\") }
            result.append(character)
            escaped = !escaped && character == "\\"
        }
        return Substring(String(result))
    }

    private static func flattenLine(_ line: Substring) -> Substring {
        var characters = Array(line)
        // Indentation, with a tab as 4 columns.
        var columns = 0
        var index = 0
        while index < characters.count, characters[index] == " " || characters[index] == "\t" {
            columns += characters[index] == "\t" ? 4 : 1
            index += 1
        }
        if columns > maxIndent {
            characters.replaceSubrange(0..<index, with: Array(repeating: " ", count: maxIndent))
            index = maxIndent
        }
        // Block markers: escape the one that would go past the limit; the rest is then text.
        var markers = 0
        while index < characters.count {
            while index < characters.count, characters[index] == " " { index += 1 }
            guard index < characters.count, let end = markerEnd(characters, at: index) else { break }
            markers += 1
            if markers > maxDepth {
                let escapeAt = characters[index].isNumber ? end - 1 : index
                characters.insert("\\", at: escapeAt)
                break
            }
            index = end
        }
        // Runs of emphasis and strike delimiters.
        var result: [Character] = []
        var run: [Character] = []
        func flushRun() {
            result += run.count > maxDelimiterRun ? run.flatMap { ["\\", $0] } : run
            run = []
        }
        for character in characters {
            if "*_~".contains(character) {
                run.append(character)
            } else {
                flushRun()
                result.append(character)
            }
        }
        flushRun()
        return Substring(String(result))
    }

    /// Where a block marker at `index` ends: `>`, or `-`, `*`, `+` or `1.`/`1)` followed by a
    /// space. Nil when there is none.
    private static func markerEnd(_ characters: [Character], at index: Int) -> Int? {
        let character = characters[index]
        if character == ">" { return index + 1 }
        func spaced(_ end: Int) -> Int? {
            end < characters.count && characters[end] == " " ? end : nil
        }
        if "-*+".contains(character) { return spaced(index + 1) }
        var digits = index
        while digits < characters.count, characters[digits].isASCII, characters[digits].isNumber, digits - index < 9 {
            digits += 1
        }
        guard digits > index, digits < characters.count, characters[digits] == "." || characters[digits] == ")" else {
            return nil
        }
        return spaced(digits + 1)
    }

    private static func blocks(_ children: MarkupChildren, depth: Int) -> [Block] {
        children.compactMap { block($0, depth: depth) }
    }

    private static func block(_ markup: Markup, depth: Int) -> Block? {
        guard depth < maxDepth else { return .paragraph([.text(markup.format())]) }
        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level, inlines(heading.children, depth: depth))
        case let paragraph as Paragraph:
            return .paragraph(inlines(paragraph.children, depth: depth))
        case let list as UnorderedList:
            return .list(MarkdownList(ordered: false, start: 1, items: items(list.listItems, depth: depth)))
        case let list as OrderedList:
            return .list(
                MarkdownList(ordered: true, start: Int(list.startIndex), items: items(list.listItems, depth: depth)))
        case let code as Markdown.CodeBlock:
            let language = code.language?.trimmingCharacters(in: .whitespaces)
            var text = code.code
            if text.hasSuffix("\n") { text.removeLast() }
            return .code(language: language?.isEmpty == false ? language : nil, text: text)
        case let quote as BlockQuote:
            return .quote(blocks(quote.children, depth: depth + 1))
        case let table as Markdown.Table:
            return .table(self.table(table, depth: depth))
        case is ThematicBreak:
            return .rule
        case let html as HTMLBlock:
            return .paragraph([.text(html.rawHTML.trimmingCharacters(in: .newlines))])
        default:
            let text = markup.format().trimmingCharacters(in: .newlines)
            return text.isEmpty ? nil : .paragraph([.text(text)])
        }
    }

    private static func items(_ items: some Sequence<ListItem>, depth: Int) -> [MarkdownList.Item] {
        items.map { item in
            let checkbox: Bool? =
                switch item.checkbox {
                case .checked: true
                case .unchecked: false
                case nil: nil
                }
            return MarkdownList.Item(checkbox: checkbox, blocks: blocks(item.children, depth: depth + 1))
        }
    }

    private static func table(_ table: Markdown.Table, depth: Int) -> MarkdownTable {
        let alignments = table.columnAlignments.map { alignment -> MarkdownTable.Alignment in
            switch alignment {
            case .center: .center
            case .right: .trailing
            case .left, nil: .leading
            }
        }
        let header = table.head.cells.map { inlines($0.children, depth: depth) }
        let rows = table.body.rows.map { row in Array(row.cells.map { inlines($0.children, depth: depth) }) }
        return MarkdownTable(alignments: alignments, header: Array(header), rows: Array(rows))
    }

    private static func inlines(_ children: MarkupChildren, depth: Int) -> [Inline] {
        children.flatMap { inline($0, depth: depth + 1) }
    }

    private static func inline(_ markup: Markup, depth: Int) -> [Inline] {
        guard depth < maxDepth else { return [.text(plainText(markup))] }
        switch markup {
        case let text as Markdown.Text: return [.text(text.string)]
        case let strong as Strong: return [.strong(inlines(strong.children, depth: depth))]
        case let emphasis as Emphasis: return [.emphasis(inlines(emphasis.children, depth: depth))]
        case let strike as Strikethrough: return [.strike(inlines(strike.children, depth: depth))]
        case let code as InlineCode: return [.code(code.code)]
        case is SoftBreak: return [.softBreak]
        case is LineBreak: return [.lineBreak]
        case let html as InlineHTML: return [.text(html.rawHTML)]
        case let link as Markdown.Link:
            let text = inlines(link.children, depth: depth)
            guard let destination = link.destination, LinkPolicy.url(destination) != nil else { return text }
            return [.link(span(text, destination: destination))]
        case let image as Markdown.Image:
            // Never loaded: shown as a link "Image: alt", or as text when it can't be a link.
            let label = [Inline.text("Image: " + plainText(image))]
            guard let source = image.source, LinkPolicy.url(source) != nil else { return label }
            return [.link(span(label, destination: source))]
        default:
            return [.text(plainText(markup))]
        }
    }

    private static func span(_ text: [Inline], destination: String) -> LinkSpan {
        LinkSpan(
            text: text, destination: destination,
            hostLabel: LinkPolicy.hostLabel(destination, text: text.map(\.plainText).joined()))
    }

    private static func plainText(_ markup: Markup) -> String {
        if let text = markup as? Markdown.Text { return text.string }
        if let code = markup as? InlineCode { return code.code }
        return markup.children.map(plainText).joined()
    }
}

extension Inline {
    /// The text without its formatting: for VoiceOver, copying, and link text checks.
    public var plainText: String {
        switch self {
        case .text(let text), .code(let text): text
        case .strong(let children), .emphasis(let children), .strike(let children): children.map(\.plainText).joined()
        case .link(let span): span.text.map(\.plainText).joined()
        case .softBreak: " "
        case .lineBreak: "\n"
        }
    }
}
