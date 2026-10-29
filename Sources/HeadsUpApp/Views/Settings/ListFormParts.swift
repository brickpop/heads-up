import HeadsUpCore
import SwiftUI

// The parts of the list-and-form editors in Settings (UX part 1, §1), shared by Services and
// Commands: the list rows, the empty card, the form's fields, the folder row, the back button
// and the bottom bar.

/// A 12 pt secondary line under a section title, with any file names in mono.
struct SecondaryLine: View {
    let text: String

    var body: some View {
        InlineMarkdownText(text)
            .font(.system(size: HUDStyle.Settings.helpSize))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The bordered card shown in place of an empty list.
struct EmptyListCard: View {
    let text: String

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Text(text)
            .font(.system(size: HUDStyle.Settings.labelSize))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HUDStyle.Settings.cardPadding)
            .overlay(
                RoundedRectangle(cornerRadius: HUDStyle.Settings.listCornerRadius)
                    .strokeBorder(
                        HUDStyle.Colors.line,
                        lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
            )
    }
}

/// An item in a Settings list: chip, name, mono command line, and a chevron. A click or
/// Enter opens its form.
struct EditorListRow: View {
    let glyph: Glyph
    let name: String
    let commandLine: String
    let isEnabled: Bool
    let open: @MainActor () -> Void

    private let isHovered = State(initialValue: false)

    var body: some View {
        Button(action: open) {
            HStack(spacing: HUDStyle.Services.rowGap) {
                Image(systemName: glyph.symbolName)
                    .frame(width: HUDStyle.Suggestions.chipSize, height: HUDStyle.Suggestions.chipSize)
                    .background(
                        HUDStyle.Colors.chip, in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.chipCornerRadius)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: HUDStyle.Settings.labelSize, weight: .semibold))
                    Text(commandLine)
                        .font(.system(size: HUDStyle.Services.metaSize).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: Symbols.disclosure)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, HUDStyle.Settings.rowHorizontalPadding)
            .padding(.vertical, HUDStyle.Settings.rowVerticalPadding)
            .background(isHovered.wrappedValue && isEnabled ? HUDStyle.Colors.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered.wrappedValue = $0 }
    }
}

/// The ghost "‹ Services" at the top of a form. It cancels the form, as Esc does.
struct FormBackButton: View {
    let title: String
    let back: @MainActor () -> Void

    var body: some View {
        Button(action: back) {
            Label(title, systemImage: Symbols.back)
        }
        .buttonStyle(.borderless)
    }
}

/// A labelled field, with optional help under it, and its problem in red.
struct FormField<Field: View>: View {
    let label: String
    var help: String?
    let problem: String?
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
            Text(label)
                .font(.system(size: HUDStyle.Settings.helpSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            field
                .accessibilityLabel(label)
            if let help {
                Text(help)
                    .font(.system(size: HUDStyle.Settings.helpSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                ProblemNote(text: problem)
            }
        }
    }
}

/// The folder a service or command runs in: the mono path, read-only, and Choose…, which opens the
/// system folder picker through the core.
struct FolderRow: View {
    let path: String
    let chooseTitle: String
    let choose: @MainActor () -> Void

    var body: some View {
        HStack {
            Text(path)
                .font(.system(size: HUDStyle.Settings.labelSize).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(chooseTitle, action: choose)
                .buttonStyle(.bordered)
        }
    }
}

/// What the bottom bar's buttons call: each is one intent of the form's store.
struct FormBarActions {
    let askRemove: @MainActor () -> Void
    let cancel: @MainActor () -> Void
    let save: @MainActor () -> Void
    let dismissBar: @MainActor () -> Void
    let discard: @MainActor () -> Void
    let confirmRemove: @MainActor () -> Void
}

/// A form's bottom bar: Remove… on the left, Cancel and Save on the right, and a save
/// problem above them; or, in its place, the discard or remove question.
struct FormBottomBar: View {
    let bar: FormBar
    let saveProblem: String?
    let saveEnabled: Bool
    /// "Remove…", or nil for a new item.
    let remove: String?
    let actions: FormBarActions

    var body: some View {
        switch bar {
        case .none:
            VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
                if let problem = saveProblem {
                    ProblemNote(text: problem)
                }
                HStack {
                    if let remove {
                        Button(action: actions.askRemove) {
                            Text(remove).foregroundStyle(HUDStyle.Colors.alert)
                        }
                        .buttonStyle(.borderless)
                    }
                    Spacer()
                    Button(Strings.ListForm.cancel, action: actions.cancel)
                        .buttonStyle(.bordered)
                    Button(Strings.ListForm.save, action: actions.save)
                        .buttonStyle(.borderedProminent)
                        .disabled(!saveEnabled)
                }
            }
        case .discard(let question, let keep, let discard):
            QuestionBar(text: question) {
                Button(keep, action: actions.dismissBar)
                    .buttonStyle(.bordered)
                Button(discard, action: actions.discard)
                    .buttonStyle(.borderless)
            }
        case .remove(let question, let cancel, let remove):
            QuestionBar(text: question) {
                Button(cancel, action: actions.dismissBar)
                    .buttonStyle(.bordered)
                Button(action: actions.confirmRemove) {
                    Text(remove).foregroundStyle(HUDStyle.Colors.alert)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

/// A question on the left and its buttons on the right, in place of the bottom bar.
/// VoiceOver announces the question when it appears.
private struct QuestionBar<Actions: View>: View {
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            actions
        }
        .accessibilityElement(children: .contain)
        .announcing(text)
    }
}
