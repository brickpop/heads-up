import HeadsUpCore
import SwiftUI

/// The prompt input in the active tab: 16 pt, borderless, with the placeholder for the tab.
/// Typing filters the actions, and Enter runs the selected row or asks the model.
/// ↑, ↓ and Esc reach the HUD through the app's key monitor, not through this field.
struct PromptField: View {
    let hud: HUDStore

    @FocusState private var isFocused: Bool

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
        // The field takes the keyboard when the HUD opens, when the tab changes (each tab
        // shows its own field) and when the model menu closes.
        .onAppear { isFocused = true }
        .onChange(of: hud.isKey) { _, isKey in
            if isKey { isFocused = true }
        }
        .onChange(of: hud.modelMenuOpen) { _, isOpen in
            if !isOpen { isFocused = true }
        }
    }
}
