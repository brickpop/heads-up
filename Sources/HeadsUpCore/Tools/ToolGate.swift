/// A choice on an approval card.
public enum CardChoice: Equatable, Sendable {
    case deny, allowOnce, alwaysAllow
}

/// What happens to a tool call before it runs (ADR-001 §9). Pure: the chat asks it for each
/// call, then runs, asks with a card, or refuses.
enum ToolGate {
    enum Step: Equatable, Sendable {
        /// Runs at once: "Allowed by rule".
        case run
        /// Waits for the user, with these choices.
        case ask([CardChoice])
        /// Off: nothing runs, "Disabled in Settings".
        case disabled
    }

    static func resolve(_ tool: ToolID, permission: ToolPermission) -> Step {
        if permission == .off { return .disabled }
        // A write always asks, whatever the settings say, and never offers Always (F4).
        if tool.effect == .write { return .ask([.deny, .allowOnce]) }
        if permission == .allow { return .run }
        // The clipboard card has no Always: that would let any later injection read it (F3).
        if tool == .clipboard { return .ask([.deny, .allowOnce]) }
        return .ask([.deny, .allowOnce, .alwaysAllow])
    }

    /// The tools offered to the model: the ones not Off (gate decision 1).
    static func offered(_ settings: ToolSettings) -> [ToolID] {
        ToolID.allCases.filter { settings[$0] != .off }
    }
}
