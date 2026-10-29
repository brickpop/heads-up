import Foundation

/// Who the Ask row asks: the active model, or nobody yet.
public enum AskTarget: Equatable, Sendable {
    case model(name: String)
    case noModel
}

/// Turns the prompt's text into suggestion rows (Action autocomplete spec, ADR-001 §5).
/// Pure: the same input always gives the same rows.
public enum Matcher {
    public static let slashLimit = 9
    public static let freeTextLimit = 6
    /// The Ask row quotes at most this many characters of the input.
    static let quoteLimit = 60

    /// - Parameters:
    ///   - input: the prompt's text, as typed.
    ///   - actions: the catalogue, in catalogue order.
    ///   - ask: who the Ask row asks.
    ///   - inConversation: the Chat tab shows a conversation with messages. Free text then
    ///     shows rows only when actions match, so typing a reply isn't hidden behind them.
    ///   - typed: the input parsed as `/start 35` or `/break 5` (`QuickTimer.parse`), and the row
    ///     that starts it when it is valid. Nil when the input isn't one.
    public static func match(
        input: String, actions: [Action], ask: AskTarget, inConversation: Bool,
        typed: (timer: QuickTimer, action: Action?)? = nil
    ) -> [SuggestionRow] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return [] }

        if query.hasPrefix("/") {
            let found = filter(actions, by: String(query.dropFirst()))
            if let action = typed?.action { return [.action(action)] }
            switch typed?.timer {
            // Words that still filter the catalogue ("/start foc") keep doing so.
            case .invalid(.notANumber) where !found.isEmpty, .focus, .break, nil:
                break
            case .invalid(let problem):
                return [.noMatch(problem.text), askRow(query, ask)]
            }
            if found.isEmpty {
                // A typo like "/fcous" must not be sent to the model by Enter: nothing is selected.
                return [.noMatch(Strings.Suggestions.noMatch), askRow(query, ask)]
            }
            return found.prefix(slashLimit).map { .action($0) }
        }

        if query.count < 2 {
            return inConversation ? [] : [askRow(query, ask)]
        }
        let found = filter(actions, by: query)
        if inConversation && found.isEmpty { return [] }
        return [askRow(query, ask)] + found.prefix(freeTextLimit - 1).map { .action($0) }
    }

    /// The actions where every word of `query` is in the title, the keywords or the kind.
    static func filter(_ actions: [Action], by query: String) -> [Action] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        if words.isEmpty { return actions }
        return actions.filter { action in
            let text = "\(action.title) \(action.keywords) \(action.kind.label)".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    static func askRow(_ query: String, _ ask: AskTarget) -> SuggestionRow {
        switch ask {
        case .model(let name):
            .ask(title: Strings.Suggestions.ask(name), subtitle: Strings.Suggestions.quote(query, limit: quoteLimit))
        case .noModel:
            .ask(title: Strings.Suggestions.setUpModel, subtitle: Strings.Suggestions.setUpModelSubtitle)
        }
    }
}
