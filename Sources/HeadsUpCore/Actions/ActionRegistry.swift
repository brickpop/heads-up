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
    /// The row for a typed `/start 35` or `/break 5`: made per query, never in the catalogue.
    var quickTimer: @MainActor (QuickTimer.Kind, Int) -> Action? = { _, _ in nil }

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
        // Parsed once, and the typed row made here, on the main actor; the matcher only places it.
        let typed = QuickTimer.parse(input.trimmingCharacters(in: .whitespacesAndNewlines)).map {
            timer -> (timer: QuickTimer, action: Action?) in
            switch timer {
            case .focus(let minutes): (timer, quickTimer(.focus, minutes))
            case .break(let minutes): (timer, quickTimer(.break, minutes))
            case .invalid: (timer, nil)
            }
        }
        return Matcher.match(input: input, actions: actions, ask: ask, inConversation: inConversation, typed: typed)
    }
}
