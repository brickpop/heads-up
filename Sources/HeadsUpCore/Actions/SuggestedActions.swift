/// An action id as a model sent it through `suggest_actions` (ADR-001 §5, F1). It is its own
/// type so it is never used as an `ActionID` by accident: the only way from it to an action is
/// `ActionResolving.resolve`.
public struct SuggestedActionID: Hashable, Codable, Sendable {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// What the chat needs from the catalogue for suggested actions (contract rule 3).
@MainActor
protocol ActionResolving: AnyObject {
    /// The action a suggested id names, or nil unless it exists now **and** may be suggested
    /// (F1). Checked when the ids arrive, when a pinned chat loads, and at the click.
    func resolve(_ id: SuggestedActionID) -> Action?
    /// The actions a model may suggest now, in catalogue order: the request's schema enum, and
    /// the id → title list in the tool's description.
    var suggestable: [Action] { get }
    /// A suggested id that names a real action which doesn't apply now (Start for a service
    /// already running): shown disabled, with why. Never run.
    func unavailable(_ id: SuggestedActionID) -> UnavailableAction?
}

extension ActionRegistry: ActionResolving {
    public func resolve(_ id: SuggestedActionID) -> Action? {
        actions.first { $0.id.rawValue == id.raw && $0.suggest != .never }
    }

    public var suggestable: [Action] {
        actions.filter { $0.suggest != .never }
    }

    public func unavailable(_ id: SuggestedActionID) -> UnavailableAction? {
        explainers.lazy.compactMap { $0(id) }.first
    }
}
