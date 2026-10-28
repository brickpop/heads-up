import HeadsUpCore
import SwiftUI

/// The actions a reply suggests, in one row at the end of the whole reply (the core places it
/// there once the reply has finished): wrapping 30 pt secondary buttons with an icon and a
/// label from the action registry, never the model's own words (F1). An action that no
/// longer applies is disabled, its tooltip saying why. A service action asks first: the row
/// turns into its question, with the command and folder, Cancel and the confirm button.
/// Every button waits out the guard (F6), and none is the default.
struct ActionButtonsView: View {
    let chat: ChatStore
    let block: ActionButtonsScreen

    var body: some View {
        ArmedTimeline(armedAt: block.armedAt) { isArmed in
            Group {
                if let confirm = block.confirm {
                    SuggestedConfirmView(chat: chat, confirm: confirm)
                } else {
                    FlowLayout(spacing: HUDStyle.Actions.gap) {
                        ForEach(block.buttons, id: \.id) { button in
                            // An action that no longer applies stays an enabled control that does
                            // nothing and looks disabled: macOS often hides the tooltip of a disabled
                            // button, and the tooltip is the only place its reason shows.
                            Button {
                                guard button.isEnabled else { return }
                                _ = chat.runSuggested(block.id, button.id)
                            } label: {
                                Label(button.title, systemImage: button.glyph.symbolName)
                                    .foregroundStyle(button.isEnabled ? Color.primary : Color.secondary)
                                    .opacity(button.isEnabled ? 1 : HUDStyle.Chat.unarmedOpacity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            // A service's command and folder, or why the action no longer applies.
                            .help(button.help ?? "")
                            .accessibilityHint(button.help ?? "")
                            .accessibilityRespondsToUserInteraction(button.isEnabled)
                        }
                    }
                }
            }
            .opacity(isArmed ? 1 : HUDStyle.Chat.unarmedOpacity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.accessibilityLabel)
    }
}

/// "Start Postgres?" with what will run, in mono, then Cancel and the confirm button.
/// Announced when it appears.
private struct SuggestedConfirmView: View {
    let chat: ChatStore
    let confirm: SuggestedConfirm

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
            Text(confirm.question)
                .font(.system(size: HUDStyle.Settings.labelSize, weight: .semibold))
            // What will run: "npm run dev · ~/code/web-app", or nothing when there is neither.
            if let detail = confirm.detail {
                Text(detail)
                    .font(.system(size: HUDStyle.Services.metaSize).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    // The core caps each part at 200 characters; the line is cut to one line here,
                    // and the tooltip has it whole.
                    .help(confirm.help ?? detail)
            }
            HStack(spacing: HUDStyle.Footer.keyGap) {
                Spacer()
                Button(confirm.cancel) { chat.cancelSuggested() }
                    .buttonStyle(.borderless)
                Button(confirm.confirm) { _ = chat.confirmSuggested() }
                    .buttonStyle(.bordered)
                    .help(confirm.help ?? "")
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(confirm.question).post() }
    }
}
