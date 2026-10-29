/// The adapters that may make macOS ask the user for a permission (Calendar, Reminders,
/// Automation, notifications) report it here, around the request call. While any request is
/// pending, the HUD sits under the prompt and stays open (`HUDPanel.permissionPromptBegan`).
@MainActor
final class PermissionPrompts {
    /// Set once the HUD exists; the adapters are made before it.
    weak var panel: HUDPanel?
    private var pending = 0

    func begin() {
        pending += 1
        if pending == 1 { panel?.permissionPromptBegan() }
    }

    func end() {
        guard pending > 0 else { return }
        pending -= 1
        if pending == 0 { panel?.permissionPromptEnded() }
    }
}
