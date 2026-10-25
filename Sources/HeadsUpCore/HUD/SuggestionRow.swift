/// One row of the suggestion list under the prompt (ADR-001 amendment 1).
public enum SuggestionRow: Equatable {
    /// "Ask <model>" with the quoted input, or "Set up a model to chat" with "Settings → Models".
    case ask(title: String, subtitle: String)
    case action(Action)
    /// "No matching actions": shown for a slash query with no match. Never selectable.
    case noMatch(String)

    public var isSelectable: Bool {
        if case .noMatch = self { return false }
        return true
    }
}

/// The left side of the footer: keyboard hints, or a toast in their place for 2.6 s.
public enum FooterLeft: Equatable, Sendable {
    case hints([Hint])
    case toast(String)
}

/// One keyboard hint in the footer: its keycaps and what they do, e.g. ["↑", "↓"] "navigate".
public struct Hint: Equatable, Sendable {
    /// One string per keycap.
    public let keys: [String]
    public let label: String

    public init(keys: [String], label: String) {
        self.keys = keys
        self.label = label
    }
}

/// What a row shows (Action autocomplete spec, "Row anatomy"). The Ask row is a Chat row
/// with the sparkle glyph; "No matching actions" has only its text.
extension SuggestionRow {
    public var title: String {
        switch self {
        case .ask(let title, _): title
        case .action(let action): action.title
        case .noMatch(let text): text
        }
    }

    public var subtitle: String {
        switch self {
        case .ask(_, let subtitle): subtitle
        case .action(let action): action.subtitle
        case .noMatch: ""
        }
    }

    public var kindLabel: String {
        switch self {
        case .ask: ActionKind.chat.label
        case .action(let action): action.kind.label
        case .noMatch: ""
        }
    }

    public var glyph: Glyph {
        switch self {
        case .ask, .noMatch: .sparkle
        case .action(let action): action.glyph
        }
    }
}

/// What last moved the selection, so VoiceOver announces only the changes the user made
/// with the keyboard, not the pointer passing over rows.
public enum SelectionChange: Equatable, Sendable {
    /// A keystroke in the prompt reset it to the first row.
    case typing
    /// ↑ or ↓.
    case keyboard
    /// The pointer moved onto a row.
    case pointer
}
