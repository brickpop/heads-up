import Combine
import Foundation
import HeadsUpCore
import SwiftUI

/// The prompt input in the active tab: 16 pt, borderless, with the placeholder for the tab.
/// Typing filters the actions, and Enter runs the selected row or asks the model.
/// ↑, ↓ and Esc reach the HUD through the app's key monitor, not through this field.
struct PromptField: View {
    let hud: HUDStore

    @FocusState private var isFocused: Bool
    /// Whether the field had the keyboard when the HUD last lost it. A Settings field that had
    /// it gets it back from macOS instead; after a close, the field takes it on the next open.
    private let hadFocus = State(initialValue: true)

    var body: some View {
        TextField(text: Binding(get: { hud.input }, set: { hud.setInput($0) }), prompt: Text(hud.placeholder)) {
            Text(Strings.Prompt.accessibilityLabel)
        }
        .textFieldStyle(.plain)
        .font(.system(size: HUDStyle.Prompt.fontSize))
        .autocorrectionDisabled()
        .focused($isFocused)
        // onSubmit waits while an input method is composing, so Enter there picks the candidate.
        .onSubmit { hud.submit() }
        // The field takes the keyboard when the HUD becomes key, when the tab changes (each
        // tab shows its own field), when the model menu closes and after a plain click in the
        // chat. A field made before the HUD is first key waits for that: focus set early would
        // already be true by then.
        .onAppear { if hud.isKey { isFocused = true } }
        .onChange(of: hud.isKey) { _, isKey in
            if isKey {
                if hadFocus.wrappedValue { isFocused = true }
            } else {
                hadFocus.wrappedValue = isFocused || !hud.isOpen
                // Let go while the HUD isn't key, so taking it back is a change SwiftUI acts
                // on: setting a focus that is already true would leave the field without a caret.
                isFocused = false
            }
        }
        .onChange(of: hud.modelMenuOpen) { _, isOpen in
            if !isOpen { isFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusPrompt)) { _ in
            isFocused = true
        }
    }
}

extension Notification.Name {
    /// Asks the prompt to take the keyboard back: `HUDPanel` posts it after a plain click in
    /// the chat.
    static let focusPrompt = Notification.Name("HeadsUp.focusPrompt")
}
