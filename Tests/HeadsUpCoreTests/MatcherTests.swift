import Testing

@testable import HeadsUpCore

/// A catalogue shaped like the spec's, with a local model, a service and an ssh command,
/// so the spec's example queries have something to find.
@MainActor
private func catalogue() -> [Action] {
    func action(_ id: String, _ title: String, _ subtitle: String, _ kind: ActionKind, _ keywords: String) -> Action {
        Action(
            id: ActionID(id), title: title, subtitle: subtitle, kind: kind, glyph: .plus, keywords: keywords,
            suggest: .never, run: {})
    }
    return [
        action(
            "focus.start:25", "Start 25 min focus", "pomodoro · focus session", .focus,
            "pomodoro focus timer work start"),
        action(
            "focus.start:40", "Start 40 min focus", "pomodoro · focus session", .focus,
            "pomodoro focus timer work start"),
        action(
            "focus.start:50", "Start 50 min focus", "pomodoro · focus session", .focus,
            "pomodoro focus timer work start"),
        action("focus.break", "Take a break now", "pomodoro · break options", .focus, "pomodoro break rest"),
        action(
            "caffeine.on:60", "Keep awake for 1 hour", "caffeine · prevent sleep", .caffeine,
            "caffeine awake sleep screensaver on"),
        action(
            "caffeine.on:120", "Keep awake for 2 hours", "caffeine · prevent sleep", .caffeine,
            "caffeine awake sleep screensaver on"),
        action(
            "caffeine.on", "Keep awake until turned off", "caffeine · prevent sleep", .caffeine,
            "caffeine awake sleep screensaver on"),
        action(
            "model.use:1", "Switch model to Llama 3.1 8B", "Ollama · llama3.1:8b", .model, "model switch llm use ollama"
        ),
        action(
            "service.start:1", "Start Postgres", "postgres -D ./data · ~/db", .service,
            "service server run start launch"),
        action(
            "command.run:1", "Run Deploy", "ssh deploy@prod ./deploy.sh", .command,
            "command terminal shell run ssh deploy@prod ./deploy.sh"),
        action("chat.pinned", "Pinned chats", "3 saved", .chat, "pinned saved history chats"),
        action("chat.new", "New chat", "clear the current conversation", .chat, "new chat clear reset"),
        action("theme.toggle", "Toggle theme", "appearance · Dark → Light", .action, "theme dark light appearance"),
    ]
        + Tab.allCases.map { tab in
            action(
                "view.open:\(tab.rawValue)", "Go to \(tab.title)", "view · ⌘\(tab.number)", .view,
                "open view go \(tab.rawValue)")
        }
}

private let llama = AskTarget.model(name: "Llama 3.1 8B")

private func titles(_ rows: [SuggestionRow]) -> [String] {
    rows.map { row in
        switch row {
        case .ask(let title, _): title
        case .action(let action): action.title
        case .noMatch(let text): text
        }
    }
}

@MainActor
@Suite struct MatcherTests {
    @Test func focusShowsAskFirstThenFiveActions() {
        let rows = Matcher.match(input: "focus", actions: catalogue(), ask: llama, inConversation: false)
        #expect(rows.count == 6)
        #expect(
            titles(rows) == [
                "Ask Llama 3.1 8B", "Start 25 min focus", "Start 40 min focus", "Start 50 min focus",
                "Take a break now", "Go to Focus",
            ])
        #expect(rows[0] == .ask(title: "Ask Llama 3.1 8B", subtitle: "“focus”"))
    }

    @Test func llamaFindsTheModelThroughItsProvider() {
        let rows = Matcher.match(input: "llama", actions: catalogue(), ask: llama, inConversation: false)
        #expect(titles(rows) == ["Ask Llama 3.1 8B", "Switch model to Llama 3.1 8B"])
    }

    @Test func sshFindsTheCommandThroughItsCommandLine() {
        let rows = Matcher.match(input: "ssh", actions: catalogue(), ask: llama, inConversation: false)
        #expect(titles(rows) == ["Ask Llama 3.1 8B", "Run Deploy"])
    }

    @Test func aSlashAloneListsTheFirstNineActionsWithNoAskRow() {
        let rows = Matcher.match(input: "/", actions: catalogue(), ask: llama, inConversation: false)
        #expect(rows.count == 9)
        #expect(titles(rows) == catalogue().prefix(9).map(\.title))
    }

    @Test func slashFiltersByTheTextAfterIt() {
        let rows = Matcher.match(input: "/awake", actions: catalogue(), ask: llama, inConversation: false)
        #expect(titles(rows) == ["Keep awake for 1 hour", "Keep awake for 2 hours", "Keep awake until turned off"])
    }

    @Test func aSlashTypoShowsNoMatchThenTheAskRow() {
        let rows = Matcher.match(input: "/fcous", actions: catalogue(), ask: llama, inConversation: false)
        #expect(rows == [.noMatch("No matching actions"), .ask(title: "Ask Llama 3.1 8B", subtitle: "“/fcous”")])
        #expect(rows[0].isSelectable == false)
    }

    /// The typed `/start 35` comes in parsed, with its row; the matcher only places it.
    @Test func aTypedTimerIsPlacedAsGiven() {
        let row = Action(
            id: ActionID("focus.start:any:35"), title: "Start 35 min focus", subtitle: "focus · ends 3:42 PM",
            kind: .focus, glyph: .timer, keywords: "", suggest: .never, run: {})
        let started = Matcher.match(
            input: "/start 35", actions: catalogue(), ask: llama, inConversation: false, typed: (.focus(35), row))
        #expect(started == [.action(row)])
        let bad = Matcher.match(
            input: "/start 0", actions: catalogue(), ask: llama, inConversation: false,
            typed: (.invalid(.outOfRange(.focus)), nil))
        #expect(
            bad == [
                .noMatch("A focus can be 1 to 180 minutes"), .ask(title: "Ask Llama 3.1 8B", subtitle: "“/start 0”"),
            ])
        // Words that still find actions keep filtering.
        let words = Matcher.match(
            input: "/start foc", actions: catalogue(), ask: llama, inConversation: false,
            typed: (.invalid(.notANumber(.focus)), nil))
        #expect(titles(words).first == "Start 25 min focus")
    }

    @Test func everyWordMustMatch() {
        let rows = Matcher.match(input: "start 50", actions: catalogue(), ask: llama, inConversation: false)
        #expect(titles(rows) == ["Ask Llama 3.1 8B", "Start 50 min focus"])
    }

    @Test func theKindLabelIsSearchedToo() {
        let onlyByKind = Action(
            id: ActionID("service.start:2"), title: "Start Redis", subtitle: "redis-server", kind: .service,
            glyph: .server, keywords: "", suggest: .never, run: {})
        let rows = Matcher.match(input: "/service", actions: [onlyByKind], ask: llama, inConversation: false)
        #expect(titles(rows) == ["Start Redis"])
    }

    @Test func matchingIgnoresCaseAndSurroundingSpaces() {
        let rows = Matcher.match(input: "  KILL  ", actions: catalogue(), ask: llama, inConversation: false)
        #expect(rows == [.ask(title: "Ask Llama 3.1 8B", subtitle: "“KILL”")])
    }

    @Test func oneCharacterShowsOnlyTheAskRow() {
        let rows = Matcher.match(input: "f", actions: catalogue(), ask: llama, inConversation: false)
        #expect(titles(rows) == ["Ask Llama 3.1 8B"])
    }

    @Test func emptyInputShowsNothing() {
        #expect(Matcher.match(input: "   ", actions: catalogue(), ask: llama, inConversation: false).isEmpty)
    }

    @Test func inAConversationRowsShowOnlyWhenActionsMatch() {
        let actions = catalogue()
        #expect(Matcher.match(input: "f", actions: actions, ask: llama, inConversation: true).isEmpty)
        #expect(Matcher.match(input: "thanks a lot", actions: actions, ask: llama, inConversation: true).isEmpty)
        let rows = Matcher.match(input: "pomodoro", actions: actions, ask: llama, inConversation: true)
        #expect(titles(rows).first == "Ask Llama 3.1 8B")
        #expect(rows.count == 5)
    }

    @Test func theAskRowQuotesAtMostSixtyCharacters() {
        let long = String(repeating: "a", count: 70)
        let rows = Matcher.match(input: long, actions: [], ask: llama, inConversation: false)
        #expect(rows == [.ask(title: "Ask Llama 3.1 8B", subtitle: "“" + String(repeating: "a", count: 60) + "…”")])
    }

    @Test func withNoModelTheAskRowSetsOneUp() {
        let rows = Matcher.match(input: "hello", actions: [], ask: .noModel, inConversation: false)
        #expect(rows == [.ask(title: "Set up a model to chat", subtitle: "Settings → Models")])
    }
}
