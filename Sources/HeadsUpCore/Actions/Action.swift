/// An action's stable id, e.g. "focus.start:50", "view.open:services".
public struct ActionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// What an action is about: shown right-aligned on its row, and matched by the search.
public enum ActionKind: String, CaseIterable, Sendable {
    case chat, focus, caffeine, model, service, command, view, action

    public var label: String { Strings.ActionKinds.label(self) }
}

/// Whether a model may suggest this action in a reply, and how it runs then (ADR-001 §5, F1).
public enum SuggestPolicy: Equatable, Sendable {
    case never
    case oneClick
    case confirm(Confirmation)
}

/// What the user confirms before a suggested action runs: the verb, the name, and for a
/// service the command and the folder it runs in.
public struct Confirmation: Equatable, Sendable {
    public let verb: String
    public let name: String
    public let command: String?
    public let cwd: String?

    public init(verb: String, name: String, command: String? = nil, cwd: String? = nil) {
        self.verb = verb
        self.name = name
        self.command = command
        self.cwd = cwd
    }
}

/// One entry of the action catalogue: a row in the suggestions, and what it does.
public struct Action: Identifiable {
    public let id: ActionID
    public let title: String
    public let subtitle: String
    public let kind: ActionKind
    public let glyph: Glyph
    /// Extra words the search matches, separated by spaces.
    public let keywords: String
    public let suggest: SuggestPolicy
    public let run: @MainActor () -> Void

    public init(
        id: ActionID, title: String, subtitle: String, kind: ActionKind, glyph: Glyph,
        keywords: String, suggest: SuggestPolicy, run: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.glyph = glyph
        self.keywords = keywords
        self.suggest = suggest
        self.run = run
    }
}

extension Action: Equatable {
    /// Two actions are equal when everything shown and matched is; `run` can't be compared.
    public static func == (lhs: Action, rhs: Action) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle && lhs.kind == rhs.kind
            && lhs.glyph == rhs.glyph && lhs.keywords == rhs.keywords && lhs.suggest == rhs.suggest
    }
}
