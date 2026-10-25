import HeadsUpCore
import SwiftUI

/// A reply's Markdown, block by block, as the core parsed and sanitized it (UX part 1, §8).
/// Blocks are 10 pt apart; lists and quotes hold blocks of their own.
struct MarkdownBlocksView: View {
    let blocks: [BlockScreen]
    let chat: ChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Chat.blockGap) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block, chat: chat)
            }
        }
    }
}

private struct BlockView: View {
    let block: BlockScreen
    let chat: ChatStore

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineTextView(
                runs: text, openLink: { chat.openLink($0) }, size: Self.headingSize(level), weight: .semibold,
                lineHeight: HUDStyle.Chat.headingLineHeight
            )
            .foregroundStyle(level >= 4 ? Color.secondary : Color.primary)
            .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            InlineTextView(runs: text, openLink: { chat.openLink($0) })
        case .list(let list):
            ListBlockView(list: list, chat: chat)
        case .code(let code):
            CodeBlockView(code: code, copy: { chat.copyCode(code.id) })
        case .quote(let blocks):
            HStack(alignment: .top, spacing: HUDStyle.Chat.quotePadding) {
                HUDStyle.Colors.line
                    .frame(width: HUDStyle.Chat.quoteBarWidth)
                    .accessibilityHidden(true)
                MarkdownBlocksView(blocks: blocks, chat: chat)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let table):
            TableBlockView(table: table, chat: chat)
        case .rule:
            Hairline().padding(.vertical, HUDStyle.Chat.ruleMargin)
        }
    }

    /// H1 18, H2 16, H3 and below 14.
    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 18
        case 2: 16
        default: 14
        }
    }
}

/// A bullet, numbered or task list. Numbers sit right-aligned in a 20 pt column; bullets
/// change with depth (dot, ring, dash); task items show a read-only box.
private struct ListBlockView: View {
    let list: ListBlock
    let chat: ChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Chat.listItemGap) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: HUDStyle.Chat.listGap) {
                    marker(item)
                        .frame(width: HUDStyle.Chat.listMarkerWidth, alignment: .trailing)
                        .accessibilityHidden(item.checked == nil)
                    MarkdownBlocksView(blocks: item.blocks, chat: chat)
                }
            }
        }
    }

    @ViewBuilder private func marker(_ item: ListBlock.Item) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? Symbols.taskOn : Symbols.taskOff)
                .foregroundStyle(.secondary)
        } else if let marker = item.marker {
            Text(marker)
                .font(.system(size: HUDStyle.Chat.bodySize).monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            let size = HUDStyle.Chat.listDotSize
            switch list.depth {
            case 0: Circle().fill(.tertiary).frame(width: size, height: size)
            case 1: Circle().strokeBorder(.tertiary, lineWidth: 1).frame(width: size, height: size)
            default: Capsule().fill(.tertiary).frame(width: size + 2, height: 1.5)
            }
        }
    }
}

/// A code block: a card on the code background with the language and Copy, then the code in
/// mono, wrapped and selectable.
private struct CodeBlockView: View {
    let code: CodeBlock
    let copy: @MainActor () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(code.language)
                    .font(.system(size: HUDStyle.Keycap.fontSize, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: copy) {
                    Label(code.copy, systemImage: Symbols.copy)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, HUDStyle.Chat.codeHorizontalPadding)
            .frame(height: HUDStyle.Chat.codeHeaderHeight)
            Hairline()
            Text(code.text)
                .font(.system(size: HUDStyle.Chat.codeSize).monospaced())
                .lineSpacing(
                    HUDStyle.lineSpacing(
                        size: HUDStyle.Chat.codeSize, lineHeight: HUDStyle.Chat.codeLineHeight, monospaced: true)
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, HUDStyle.Chat.codeVerticalPadding)
                .padding(.horizontal, HUDStyle.Chat.codeHorizontalPadding)
        }
        .background(HUDStyle.Colors.codeBackground, in: RoundedRectangle(cornerRadius: HUDStyle.Chat.codeRadius))
        .overlay(
            RoundedRectangle(cornerRadius: HUDStyle.Chat.codeRadius)
                .strokeBorder(
                    HUDStyle.Colors.line, lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
        )
    }
}

/// A table in a bordered card: the header on the raised fill, hairlines between rows, each
/// column aligned as the Markdown says. A wide table scrolls sideways inside its card.
private struct TableBlockView: View {
    let table: TableBlock
    let chat: ChatStore

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, column: column, size: HUDStyle.Chat.tableHeaderSize, weight: .semibold)
                            .foregroundStyle(.secondary)
                    }
                }
                .background(HUDStyle.Colors.raise)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Hairline()
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            cellView(cell, column: column, size: HUDStyle.Chat.tableCellSize)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: HUDStyle.Chat.tableRadius))
        .overlay(
            RoundedRectangle(cornerRadius: HUDStyle.Chat.tableRadius)
                .strokeBorder(
                    HUDStyle.Colors.line, lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
        )
    }

    private func cellView(
        _ cell: InlineText, column: Int, size: CGFloat, weight: Font.Weight = .regular
    ) -> some View {
        InlineTextView(runs: cell, openLink: { chat.openLink($0) }, size: size, weight: weight)
            .padding(.vertical, HUDStyle.Chat.tableCellVertical)
            .padding(.horizontal, HUDStyle.Chat.tableCellHorizontal)
            // Each cell fills its column, so the header's fill runs the whole row.
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment(column), vertical: .center))
            .gridColumnAlignment(alignment(column))
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        guard table.alignments.indices.contains(column) else { return .leading }
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
