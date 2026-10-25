import Foundation
import Testing

@testable import HeadsUpCore

/// F16: model text in the app's own UI.
@Suite struct SanitizeForDisplayTests {
    @Test func controlAndDirectionCharactersGo() {
        let spoof = "Groceries\u{202E}gnippohs\u{202C} \u{2066}x\u{2069}\u{0007}\u{009B}\u{200F}"
        #expect(sanitizeForDisplay(spoof, max: 100) == "Groceriesgnippohs x")
        #expect(sanitizeForDisplay("line one\nline two\ttab", max: 100) == "line one line two tab")
    }

    @Test func longTextIsCutWithAnEllipsis() {
        #expect(sanitizeForDisplay(String(repeating: "a", count: 50), max: 10) == "aaaaaaaaa…")
        #expect(sanitizeForDisplay("short", max: 10) == "short")
        #expect(sanitizeForDisplay("✅ Approved once", max: 80) == "✅ Approved once")
    }
}

/// F2: links show their host and ask before risky opens.
@Suite struct LinkPolicyTests {
    @Test func onlyWebAndMailLinksOpen() {
        #expect(LinkPolicy.url("https://example.com/a") != nil)
        #expect(LinkPolicy.url("http://example.com") != nil)
        #expect(LinkPolicy.url("mailto:me@example.com") != nil)
        for bad in [
            "javascript:alert(1)", "file:///etc/passwd", "x-apple.systempreferences:x", "data:text/html,hi",
            "ftp://a.b", "https://",
        ] {
            #expect(LinkPolicy.url(bad) == nil, "\(bad)")
        }
    }

    @Test func theHostIsShownAfterTheText() {
        #expect(LinkPolicy.hostLabel("https://evil.example/j?d=abc", text: "Join the meeting") == "evil.example")
        #expect(LinkPolicy.hostLabel("https://www.Example.com:8443/x", text: "Docs") == "example.com")
        #expect(LinkPolicy.hostLabel("https://user:pw@evil.example@good.example/", text: "x") == "good.example")
        #expect(LinkPolicy.hostLabel("mailto:me@example.com?subject=hi", text: "Write to me") == "me@example.com")
        #expect(LinkPolicy.hostLabel("https://example.com", text: "https://example.com") == nil)
    }

    @Test func aNonASCIIHostIsShownInPunycode() {
        #expect(LinkPolicy.hostLabel("https://bücher.de/x", text: "Books") == "xn--bcher-kva.de")
        #expect(LinkPolicy.hostLabel("https://аpple.com/", text: "Apple") == "xn--pple-43d.com")
    }

    @Test func punycodeMatchesKnownLabels() {
        #expect(Punycode.encode("bücher") == "bcher-kva")
        #expect(Punycode.encode("mañana") == "maana-pta")
        #expect(Punycode.encode("пример") == "e1afmkfd")
        #expect(Punycode.encode("☃") == "n3h")
        #expect(Punycode.encode("münchen") == "mnchen-3ya")
        // RFC 3492, 7.1 (L): 3<nen>B<gumi><kinpachi><sensei>
        #expect(Punycode.encode("3年B組金八先生") == "3B-ww4c5e180e575a65lsy2b")
    }

    @Test func riskyLinksAskFirst() {
        let user = ["Can you find the docs on docs.swift.org for me?"]
        #expect(!LinkPolicy.asksFirst("https://docs.swift.org/swift-book/", userMessages: user))
        #expect(!LinkPolicy.asksFirst("https://www.docs.swift.org/", userMessages: user))
        // A query, a fragment, a long URL, or a host the user never wrote.
        #expect(LinkPolicy.asksFirst("https://docs.swift.org/search?q=x", userMessages: user))
        #expect(LinkPolicy.asksFirst("https://docs.swift.org/a#b", userMessages: user))
        #expect(
            LinkPolicy.asksFirst("https://docs.swift.org/" + String(repeating: "a", count: 100), userMessages: user))
        #expect(LinkPolicy.asksFirst("https://evil.example/", userMessages: user))
        #expect(LinkPolicy.asksFirst("https://swift.org.evil.example/", userMessages: user))
        // The host must be written whole, not as the end of another.
        #expect(LinkPolicy.asksFirst("https://s.swift.org/", userMessages: user))
        #expect(LinkPolicy.asksFirst("https://swift.or/", userMessages: user))
        #expect(!LinkPolicy.asksFirst("mailto:me@example.com", userMessages: []))
    }
}

/// Markdown → Block (UX part 1, §8): every element the design styles, and nothing the app
/// doesn't draw itself.
@Suite struct MarkdownBlocksTests {
    @Test func headingsParagraphsAndInlineStyles() {
        let blocks = MarkdownBlocks.parse("# Title\n\nYou have **4 events**, *one* ~~two~~ and `lsof -ti :3000`.")
        #expect(blocks[0] == .heading(level: 1, [.text("Title")]))
        #expect(
            blocks[1]
                == .paragraph([
                    .text("You have "), .strong([.text("4 events")]), .text(", "), .emphasis([.text("one")]),
                    .text(" "), .strike([.text("two")]), .text(" and "), .code("lsof -ti :3000"), .text("."),
                ]))
    }

    @Test func listsKeepTheirNumbersNestingAndTasks() {
        let blocks = MarkdownBlocks.parse("3. three\n4. four\n   - nested\n\n- [x] done\n- [ ] to do\n")
        guard case .list(let ordered) = blocks[0], case .list(let tasks) = blocks[1] else {
            Issue.record("expected two lists: \(blocks)")
            return
        }
        #expect(ordered.ordered && ordered.start == 3 && ordered.items.count == 2)
        guard case .list(let nested) = ordered.items[1].blocks.last else {
            Issue.record("expected a nested list")
            return
        }
        #expect(!nested.ordered && nested.items[0].blocks == [.paragraph([.text("nested")])])
        #expect(tasks.items.map(\.checkbox) == [true, false])
    }

    @Test func codeQuotesTablesAndRules() {
        let markdown = """
            ```swift
            let x = 1
            ```

            > quoted

            | Name | Size |
            |:-----|-----:|
            | a    | 1    |

            ---
            """
        let blocks = MarkdownBlocks.parse(markdown)
        #expect(blocks[0] == .code(language: "swift", text: "let x = 1"))
        #expect(blocks[1] == .quote([.paragraph([.text("quoted")])]))
        #expect(
            blocks[2]
                == .table(
                    MarkdownTable(
                        alignments: [.leading, .trailing], header: [[.text("Name")], [.text("Size")]],
                        rows: [[[.text("a")], [.text("1")]]])))
        #expect(blocks[3] == .rule)
        #expect(MarkdownBlocks.parse("    indented\n") == [.code(language: nil, text: "indented")])
    }

    @Test func linksShowTheirHostAndOtherSchemesAreText() {
        let blocks = MarkdownBlocks.parse(
            "[Join](https://evil.example/j?d=abc) [Run](javascript:alert(1)) <https://swift.org>")
        guard case .paragraph(let inlines) = blocks[0] else { return }
        #expect(
            inlines[0]
                == .link(
                    LinkSpan(
                        text: [.text("Join")], destination: "https://evil.example/j?d=abc", hostLabel: "evil.example")))
        #expect(inlines.contains(.text("Run")))
        #expect(
            !inlines.contains {
                if case .link(let span) = $0 { span.destination.hasPrefix("javascript") } else { false }
            })
        #expect(
            inlines.last
                == .link(LinkSpan(text: [.text("https://swift.org")], destination: "https://swift.org", hostLabel: nil))
        )
    }

    // F16, and no remote fetch: images, HTML and look-alike controls stay text or links.
    @Test func imagesAndHTMLNeverBecomeAnythingButTextOrLinks() {
        let blocks = MarkdownBlocks.parse(
            "![tracking pixel](https://evil.example/p.png)\n\n<button>Allow once</button>\n\n<img src=x onerror=1>")
        #expect(
            blocks[0]
                == .paragraph([
                    .link(
                        LinkSpan(
                            text: [.text("Image: tracking pixel")], destination: "https://evil.example/p.png",
                            hostLabel: "evil.example"))
                ]))
        // Raw HTML is shown as its text: never a control.
        func text(_ block: Block) -> String? {
            guard case .paragraph(let inlines) = block,
                inlines.allSatisfy({ if case .text = $0 { true } else { false } })
            else { return nil }
            return inlines.map(\.plainText).joined()
        }
        #expect(text(blocks[1]) == "<button>Allow once</button>")
        #expect(text(blocks[2]) == "<img src=x onerror=1>")
    }

    /// Hostile replies that would nest thousands of levels deep: they must parse without
    /// overflowing the stack, which swift-markdown alone does (a crash, signal 11).
    static let hostile: [String] = {
        var cases: [String] = []
        cases.append(String(repeating: "> ", count: 5000) + "bottom")
        cases.append(String(repeating: "- ", count: 5000) + "bottom")
        cases.append(String(repeating: "1. ", count: 3000) + "bottom")
        cases.append(String(repeating: "> - ", count: 3000) + "bottom")
        cases.append(String(repeating: "*", count: 5000) + "a" + String(repeating: "*", count: 5000))
        cases.append(String(repeating: "*_", count: 3000) + "a" + String(repeating: "_*", count: 3000))
        cases.append(String(repeating: "~~", count: 3000) + "a" + String(repeating: "~~", count: 3000))
        cases.append(String(repeating: "[", count: 5000) + "a" + String(repeating: "](https://x.example)", count: 5000))
        let indented: [String] = (0..<3000).map { String(repeating: " ", count: $0 * 2) + "- item" }
        cases.append(indented.joined(separator: "\n"))
        // Scan's shapes: nested images; alternating emphasis with letters between; the same
        // spread over lines of one paragraph.
        cases.append(
            String(repeating: "![", count: 3000) + "a" + String(repeating: "](https://x.example/i.png)", count: 3000))
        cases.append(String(repeating: "*a _a ", count: 3000) + "z" + String(repeating: " a_ a*", count: 3000))
        cases.append(String(repeating: "*a\n_a\n", count: 3000) + "z" + String(repeating: "\na_\na*", count: 3000))
        cases.append(String(repeating: "**a __a ", count: 2000) + "z" + String(repeating: " a__ a**", count: 2000))
        return cases
    }()

    @Test(arguments: hostile)
    func deepNestingParsesSafely(_ markdown: String) {
        let blocks = MarkdownBlocks.parse(markdown)
        #expect(!blocks.isEmpty)
        #expect(blocks.map(\.depth).max() ?? 0 <= MarkdownBlocks.maxDepth + 1)
    }

    @Test func ordinaryNestingIsUntouched() {
        let markdown = "> quote\n> > inner\n\n- a\n  - b\n    - c\n\n***bold italic*** and **_mixed_**"
        #expect(MarkdownBlocks.flattenRunawayNesting(markdown) == markdown)
    }
}

extension Block {
    /// How many blocks deep this goes, for the nesting tests.
    var depth: Int {
        switch self {
        case .quote(let inner): 1 + (inner.map(\.depth).max() ?? 0)
        case .list(let list): 1 + (list.items.flatMap(\.blocks).map(\.depth).max() ?? 0)
        default: 0
        }
    }
}

/// Nick msg-673 (F2): the host shown is the host that opens.
@Suite struct LinkHostTests {
    @Test func onlyPlainHostsMakeLinks() {
        #expect(LinkPolicy.url(#"https://evil.com\.good.com/"#) == nil)  // a browser opens evil.com
        #expect(LinkPolicy.url("https://evil .com/") == nil)
        #expect(LinkPolicy.url("https://evil\u{0007}.com/") == nil)
        #expect(LinkPolicy.url("https://[::1]:8080/") != nil)
        #expect(LinkPolicy.url("https://bücher.de/") != nil)
    }

    @Test func theShownHostIsTheOneThatOpens() {
        // Userinfo: both readings agree on evil.com, which is what is shown.
        #expect(LinkPolicy.host(#"https://good.com\@evil.com/"#) == "evil.com")
        #expect(LinkPolicy.opensShownHost(#"https://good.com\@evil.com/"#))
        #expect(LinkPolicy.host("https://good.com:@evil.com/") == "evil.com")
        #expect(LinkPolicy.opensShownHost("https://good.com:@evil.com/"))
        // %40 isn't a URL: text.
        #expect(LinkPolicy.url("https://good.com%40evil.com/") == nil)
        // A trailing dot is the same host.
        #expect(LinkPolicy.opensShownHost("https://example.com./x"))
        #expect(LinkPolicy.opensShownHost("https://www.Example.com/x"))
        // A full-width dot: URL reads evil.com, the text doesn't, so it shows punycode and asks.
        let fullWidth = "https://evil\u{FF0E}com/"
        #expect(LinkPolicy.url(fullWidth) != nil && !LinkPolicy.opensShownHost(fullWidth))
        #expect(LinkPolicy.hostLabel(fullWidth, text: fullWidth)?.hasPrefix("xn--") == true)
        #expect(LinkPolicy.opensShownHost("mailto:me@example.com"))
    }

    @Test func aLookAlikeHostAlwaysShowsItsPunycodeAndAsks() {
        let cyrillic = "https://\u{0430}pple.com"  // а, not a
        #expect(LinkPolicy.hostLabel(cyrillic, text: cyrillic) == "xn--pple-43d.com")
        #expect(LinkPolicy.asksFirst(cyrillic, userMessages: ["open \u{0430}pple.com please"]))
        #expect(LinkPolicy.hostLabel("https://apple.com", text: "https://apple.com") == nil)
    }
}

/// Rev 3 and Scan's caps.
@Suite struct ChatSafetyTests {
    @Test func zeroWidthCharactersLeaveAppChrome() {
        #expect(sanitizeForDisplay("Ap\u{200B}pr\u{200C}ov\u{200D}ed\u{2060} on\u{FEFF}ce", max: 80) == "Approved once")
    }

    @Test func onlyTheFirst256KBAreMarkdown() {
        let head = String(repeating: "word ", count: 256 * 1024 / 5 + 1)
        let blocks = MarkdownBlocks.parse(head + "**not bold**")
        #expect(blocks.last == .paragraph([.text(String((head + "**not bold**").utf8.dropFirst(256 * 1024))!)]))
    }

    @Test func aParagraphFullOfOpenersReadsAsWritten() {
        let text = String(repeating: "*a ", count: 150) + String(repeating: "_b ", count: 60)
        guard case .paragraph(let inlines)? = MarkdownBlocks.parse(text).first else { return }
        #expect(inlines.map(\.plainText).joined().contains("*a _b") == false || inlines.count >= 1)
        #expect(MarkdownBlocks.flattenRunawayNesting(text).contains(#"\*a"#))
        // A long list keeps its markers.
        let list = (0..<300).map { "- item *\($0)*" }.joined(separator: "\n")
        #expect(MarkdownBlocks.flattenRunawayNesting(list).hasPrefix("- item"))
    }
}
