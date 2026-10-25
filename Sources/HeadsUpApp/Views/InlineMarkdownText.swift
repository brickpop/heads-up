import SwiftUI

/// Core copy with inline Markdown: `backticked` file names show in mono. Anything that
/// doesn't parse shows as plain text.
struct InlineMarkdownText: View {
    let text: AttributedString

    init(_ markdown: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        text = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    var body: some View {
        Text(text)
    }
}
