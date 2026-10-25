import HeadsUpCore
import SwiftUI

/// One run of Markdown text from the core, drawn as a single Text: bold, italic, strike and
/// inline code, and links in the accent colour with their host after them in secondary ink.
///
/// A link carries no real URL here. Each one gets an internal `headsup-link:<n>` address, and
/// a click comes back to `chat.openLink(id)`, so the core decides whether to open it or ask
/// first (F2). Text is selectable.
struct InlineTextView: View {
    let runs: InlineText
    let openLink: @MainActor (LinkID) -> Void
    var size = HUDStyle.Chat.bodySize
    var weight = Font.Weight.regular
    var lineHeight = HUDStyle.Chat.replyLineHeight

    var body: some View {
        let (text, links) = Self.build(runs, size: size, weight: weight)
        // SwiftUI has no tooltip per run, so a block's links show their full addresses together,
        // one per line. This text is for reading only: only `openLink(id)` opens a link.
        let addresses = runs.compactMap { $0.link?.help }.joined(separator: "\n")
        Text(text)
            .lineSpacing(HUDStyle.lineSpacing(size: size, lineHeight: lineHeight))
            .help(addresses)
            .accessibilityHint(addresses)
            .environment(
                \.openURL,
                OpenURLAction { url in
                    guard url.scheme == Self.scheme,
                        let index = Int(url.absoluteString.dropFirst(Self.scheme.count + 1)),
                        links.indices.contains(index)
                    else { return .discarded }
                    openLink(links[index])
                    return .handled
                })
    }

    private static let scheme = "headsup-link"

    /// The attributed text, and the links in the order their internal addresses number them.
    private static func build(_ runs: InlineText, size: CGFloat, weight: Font.Weight) -> (AttributedString, [LinkID]) {
        var text = AttributedString()
        var links: [LinkID] = []
        for run in runs {
            var piece = AttributedString(run.text)
            piece.font = font(for: run.style, size: size, weight: weight)
            if run.style.contains(.code) {
                piece.backgroundColor = HUDStyle.Colors.codeBackground
                // Room on both sides of inline code, made with kerning so no characters are added:
                // a copied command pastes exactly as written.
                kernLast(&text)
                kernLast(&piece)
            }
            if run.style.contains(.strike) {
                piece.strikethroughStyle = .single
                piece.foregroundColor = .secondary
            }
            if let link = run.link {
                piece.link = URL(string: "\(scheme):\(links.count)")
                piece.foregroundColor = .accentColor
                links.append(link.id)
                text += piece
                if let host = link.host {
                    var hostPiece = AttributedString(host)
                    hostPiece.font = .system(size: size, weight: weight)
                    hostPiece.foregroundColor = .secondary
                    text += hostPiece
                }
            } else {
                text += piece
            }
        }
        return (text, links)
    }

    /// Adds the inline-code spacing after the last character of `text`.
    private static func kernLast(_ text: inout AttributedString) {
        guard !text.characters.isEmpty else { return }
        let last = text.characters.index(before: text.endIndex)
        text[last..<text.endIndex].kern = HUDStyle.Chat.codeKern
    }

    /// Semibold for bold (or the block's own weight), the system italic, and mono 12.5 for code.
    private static func font(for style: Set<InlineRun.Style>, size: CGFloat, weight: Font.Weight) -> Font {
        if style.contains(.code) {
            return .system(size: HUDStyle.Chat.codeSize).monospaced()
        }
        let font = Font.system(size: size, weight: style.contains(.bold) ? .semibold : weight)
        return style.contains(.italic) ? font.italic() : font
    }
}
