import HeadsUpCore
import SwiftUI

/// The model menu, inline in the HUD body while the chip is open: "Model", one row per
/// endpoint, and Manage endpoints…. ↑, ↓ and Enter move and choose through the core, which
/// keeps the keyboard selection.
struct ModelMenuView: View {
    let model: AppModel
    let screen: ModelMenuScreen

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FocusLabel(text: screen.label)
                .padding(.horizontal, HUDStyle.Services.headerPadding)
                .padding(.vertical, HUDStyle.Footer.keyGap)
            if let empty = screen.emptyLine {
                Text(empty)
                    .font(.system(size: HUDStyle.Settings.labelSize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, HUDStyle.Services.headerPadding)
                    .padding(.vertical, HUDStyle.Footer.keyGap)
            }
            ForEach(screen.rows, id: \.id) { row in
                ModelMenuRowView(model: model, row: row)
            }
            MenuRowFrame(isSelected: screen.manageSelected) {
                Button {
                    model.manageEndpoints()
                } label: {
                    HStack(spacing: HUDStyle.Services.rowGap) {
                        Image(systemName: Glyph.sliders.symbolName)
                            .frame(width: HUDStyle.ModelMenu.chipSize, height: HUDStyle.ModelMenu.chipSize)
                            .accessibilityHidden(true)
                        Text(screen.manage)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(HUDStyle.Suggestions.padding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(screen.label)
    }
}

/// One endpoint: the CPU chip, the name with its Local tag, the provider or host with the
/// model id in mono, Start when a linked server isn't running, and the check on the active one.
private struct ModelMenuRowView: View {
    let model: AppModel
    let row: ModelMenuScreen.Row

    var body: some View {
        MenuRowFrame(isSelected: row.isSelected) {
            HStack(spacing: HUDStyle.Services.rowGap) {
                Button {
                    model.selectModel(row.id)
                } label: {
                    HStack(spacing: HUDStyle.Services.rowGap) {
                        Image(systemName: Glyph.cpu.symbolName)
                            .frame(width: HUDStyle.ModelMenu.chipSize, height: HUDStyle.ModelMenu.chipSize)
                            .background(
                                HUDStyle.Colors.chip,
                                in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.chipCornerRadius)
                            )
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: HUDStyle.Footer.keyGap) {
                                Text(row.name)
                                    .font(.system(size: HUDStyle.Settings.labelSize, weight: .semibold))
                                if let tag = row.localTag {
                                    TagPill(text: tag)
                                }
                            }
                            Text(row.detail)
                                .font(.system(size: HUDStyle.Services.metaSize).monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(row.isActive ? [.isSelected] : [])
                if let start = row.start {
                    Button(start) { model.startEndpointService(row.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if row.isActive {
                    Image(systemName: Symbols.check)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// A menu row's padding and its gray fill while it has the keyboard selection.
private struct MenuRowFrame<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(HUDStyle.ModelMenu.rowPadding)
            .background(
                isSelected ? HUDStyle.Colors.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.rowCornerRadius))
    }
}

/// A small tag next to a name: "Local", "Ollama", "Custom".
struct TagPill: View {
    let text: String
    var help: String?

    var body: some View {
        Text(text)
            .font(.system(size: HUDStyle.Keycap.fontSize, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, HUDStyle.Endpoints.tagPadding)
            .background(HUDStyle.Colors.raise2, in: Capsule())
            .help(help ?? "")
    }
}
