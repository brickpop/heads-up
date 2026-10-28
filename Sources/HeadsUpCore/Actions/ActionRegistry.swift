import Observation

/// The catalogue's sections, in the order their rows show (Action autocomplete spec).
public enum CatalogueSection: Int, CaseIterable, Comparable, Sendable {
    case focus, caffeine, model, service, command, chat, theme, view

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The action catalogue (ADR-001 §5): each feature adds a provider for its section, and the
/// registry lists their actions section by section, whatever order the providers were added in.
///
/// Providers build their actions from their store's current state each time they're read,
/// so the catalogue always matches what is running.
@MainActor
public final class ActionRegistry {
    public typealias Provider = @MainActor () -> [Action]

    private var providers: [(section: CatalogueSection, provider: Provider)] = []
    /// Say why a suggested id doesn't apply now (see `unavailable`).
    var explainers: [@MainActor (SuggestedActionID) -> UnavailableAction?] = []

    public init() {}

    /// Adds a provider to `section`, after the ones already in it.
    public func add(_ section: CatalogueSection, _ provider: @escaping Provider) {
        providers.append((section, provider))
        // A stable sort keeps the order of providers within a section.
        providers = providers.enumerated()
            .sorted { ($0.element.section, $0.offset) < ($1.element.section, $1.offset) }
            .map(\.element)
    }

    /// Every action, in catalogue order.
    public var actions: [Action] {
        providers.flatMap { $0.provider() }
    }

    public func match(input: String, ask: AskTarget, inConversation: Bool) -> [SuggestionRow] {
        Matcher.match(input: input, actions: actions, ask: ask, inConversation: inConversation)
    }
}
