import Foundation

/// The `suggest_actions` tool (ADR-001 §8.4): the model proposes up to 4 actions from the
/// catalogue, and the user clicks one, or doesn't. It isn't gated and has no row: it only adds
/// buttons, whose labels come from the registry, never from the model.
enum SuggestTool {
    static let name = "suggest_actions"
    static let maxActions = 4
    /// At most this many actions are offered, in catalogue order (Nick, slice 11).
    static let maxOffered = 64

    /// The schema, with an enum of the ids a model may suggest right now, and in the
    /// description what each id does: "focus.start:25 — Start 25 min focus". Titles are
    /// cleaned: service names are the user's own text (F16).
    static func spec(_ suggestable: [Action]) -> LLMTool {
        let offered = suggestable.prefix(maxOffered)
        let ids = offered.map(\.id)
        let list = offered.map { "\($0.id.rawValue) — \(sanitizeForDisplay($0.title, max: 80))" }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "actions": [
                    "type": "array", "maxItems": maxActions,
                    "items": ["type": "string", "enum": ids.map(\.rawValue)],
                ] as [String: Any]
            ],
            "required": ["actions"],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
        return LLMTool(
            name: name,
            description:
                "Offer the user up to 4 HeadsUp actions as buttons under your reply. The user decides; nothing runs until they click. The actions:\n"
                + list.joined(separator: "\n"),
            parameters: data)
    }

    /// The ids in the call's arguments, as sent. Anything that isn't a list of strings is none.
    static func ids(_ arguments: Data) -> [SuggestedActionID] {
        guard let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any],
            let list = object["actions"] as? [Any]
        else { return [] }
        return list.compactMap { $0 as? String }.map(SuggestedActionID.init)
    }
}

/// A suggested action waiting for "Restart Web dev server?" to be answered.
struct PendingSuggestion: Equatable, Sendable {
    /// The reply it belongs to (`ActionButtonsScreen.id`).
    let replyID: String
    let id: SuggestedActionID
    /// Its buttons ignore input for 600 ms after (F6, S2).
    let shownAt: Date
}

/// A suggested action's button.
public struct ActionButton: Equatable, Sendable, Identifiable {
    /// What `chat.runSuggested(block.id, button.id)` takes.
    public let id: String
    /// The registry's title: "Start 50 min focus".
    public let title: String
    public let glyph: Glyph
    /// False when the action no longer applies, e.g. Start for a service already running.
    public let isEnabled: Bool
    /// The tooltip: for a service, its command and folder ("npm run dev · ~/code/web-app");
    /// for a disabled button, why ("Web dev server is already running").
    public let help: String?
}

/// "Restart Web dev server?", in place of the buttons (addendum 3, F1; Yuki, slice 11).
public struct SuggestedConfirm: Equatable, Sendable {
    public let question: String
    /// "npm run dev · ~/code/web-app", in mono: registry text, never the model's. Each part is
    /// capped at 200 characters here; the view keeps it to one line.
    public let detail: String?
    /// The whole command and folder, uncut, for the tooltip (Scan I20).
    public let help: String?
    /// "Cancel": `chat.cancelSuggested()`.
    public let cancel: String
    /// "Start", "Stop" or "Restart": `chat.confirmSuggested()`.
    public let confirm: String
}

/// The buttons a reply suggested: one row at the end of the whole reply, once it has finished
/// or was stopped (Yuki, slice 11).
public struct ActionButtonsScreen: Equatable, Sendable, Identifiable {
    /// The reply's id, for `chat.runSuggested`.
    public let id: String
    public let buttons: [ActionButton]
    public let confirm: SuggestedConfirm?
    /// The row is a VoiceOver group: "Suggested actions".
    public let accessibilityLabel: String
    /// The buttons take input now; the intents check again themselves.
    public let isArmed: Bool
    /// When they start taking input; nil while the HUD isn't key.
    public let armedAt: Date?
}

/// A suggested action that no longer applies, shown disabled with the reason.
public struct UnavailableAction: Equatable, Sendable {
    public let title: String
    public let glyph: Glyph
    /// "Web dev server is already running"
    public let reason: String

    public init(title: String, glyph: Glyph, reason: String) {
        self.title = title
        self.glyph = glyph
        self.reason = reason
    }
}

/// One reply: the items after a user message, up to the next one.
struct Reply {
    /// The user message's id, or "start" before any: `ActionButtonsScreen.id`.
    let id: String
    /// Its items' indexes.
    let range: Range<Int>
    /// Its suggestions, merged in order, each once, at most 4.
    let suggested: [SuggestedActionID]
    /// False while it is still being written: its buttons don't show or act yet.
    let isFinished: Bool
}

extension ChatStore {
    /// `suggest_actions` called by the model: the ids that resolve now are kept on the step's
    /// message. The model is told they will show.
    func acceptSuggestions(_ call: ToolCall, on messageID: ChatMessage.ID) -> String {
        var kept: [SuggestedActionID] = []
        for id in SuggestTool.ids(call.arguments) where !kept.contains(id) && actions.resolve(id) != nil {
            kept.append(id)
            if kept.count == SuggestTool.maxActions { break }
        }
        if let index = items.firstIndex(where: { $0.id == messageID }), case .message(var message) = items[index] {
            message.suggested += kept.filter { !message.suggested.contains($0) }
            items[index] = .message(message)
        }
        // Counted after the reply's merge and its cap of 4, so the model hears what will show (Rev 5).
        let shown = replies().last?.suggested ?? []
        return ToolEnvelope.make(
            tool: SuggestTool.name, content: Strings.SuggestedActions.shownToModel(kept.filter(shown.contains).count))
    }

    /// The replies in the conversation, with their merged suggestions.
    func replies() -> [Reply] {
        var replies: [Reply] = []
        var start = 0
        var id = "start"
        func close(_ end: Int) {
            guard end > start else { return }
            var merged: [SuggestedActionID] = []
            for item in items[start..<end] {
                guard case .message(let message) = item, message.role == .assistant else { continue }
                for suggested in message.suggested where !merged.contains(suggested) { merged.append(suggested) }
            }
            // The reply being written, if any, is the last one.
            let finished = !(isBusy && end == items.count)
            replies.append(
                Reply(
                    id: id, range: start..<end, suggested: Array(merged.prefix(SuggestTool.maxActions)),
                    isFinished: finished))
        }
        for (index, item) in items.enumerated() {
            if case .message(let message) = item, message.role == .user {
                close(index)
                start = index + 1
                id = message.id
            }
        }
        close(items.count)
        return replies
    }

    /// The reply with this id, if it has finished: buttons never show or act mid-stream.
    private func finishedReply(_ id: String) -> Reply? {
        replies().first { $0.id == id && $0.isFinished }
    }

    /// The reply just ended or was stopped: its buttons appear now, and take input 600 ms later.
    func suggestionsSettled() {
        guard let last = replies().last, !last.suggested.isEmpty else { return }
        suggestionsShownAt[last.id] = clock.now
    }

    /// The row after a finished reply, its ids checked again now: available actions are
    /// buttons, ones that no longer apply are disabled with why, others are dropped (F1).
    func suggestionScreen(_ reply: Reply) -> ActionButtonsScreen? {
        guard !reply.suggested.isEmpty, reply.isFinished else { return nil }
        let buttons = reply.suggested.compactMap { id -> ActionButton? in
            if let action = actions.resolve(id) {
                var help: String?
                if case .confirm(let confirmation) = action.suggest {
                    help = Strings.SuggestedActions.detail(confirmation, max: 0)
                }
                return ActionButton(
                    id: id.raw, title: action.title, glyph: action.glyph, isEnabled: true, help: help)
            }
            return actions.unavailable(id).map {
                ActionButton(
                    id: id.raw, title: sanitizeForDisplay($0.title, max: 80), glyph: $0.glyph, isEnabled: false,
                    help: sanitizeForDisplay($0.reason, max: 120))
            }
        }
        guard !buttons.isEmpty else { return nil }
        var confirm: SuggestedConfirm?
        if let pending = pendingSuggestion, pending.replyID == reply.id, let action = actions.resolve(pending.id),
            case .confirm(let confirmation) = action.suggest
        {
            confirm = SuggestedConfirm(
                question: Strings.SuggestedActions.question(
                    verb: confirmation.verb, name: sanitizeForDisplay(confirmation.name, max: 64)),
                detail: Strings.SuggestedActions.detail(confirmation, max: 200),
                help: Strings.SuggestedActions.detail(confirmation, max: 0), cancel: Strings.SuggestedActions.cancel,
                confirm: confirmation.verb)
        }
        let shownAt = suggestionsShownAt[reply.id] ?? clock.now
        let armedFrom = pendingSuggestion?.replyID == reply.id ? pendingSuggestion?.shownAt ?? shownAt : shownAt
        return ActionButtonsScreen(
            id: reply.id, buttons: buttons, confirm: confirm, accessibilityLabel: Strings.SuggestedActions.group,
            isArmed: guardAllows(armedFrom), armedAt: armedAt(armedFrom))
    }

    /// A suggested button. It is resolved again now (F1): a one-click action runs, one that
    /// needs confirming shows the confirm, and anything else is refused. False when nothing
    /// happened, also when the action guard ignored the press (F6, S2).
    @discardableResult
    public func runSuggested(_ replyID: String, _ actionID: String) -> Bool {
        let id = SuggestedActionID(actionID)
        guard let reply = finishedReply(replyID), reply.suggested.contains(id), let action = actions.resolve(id),
            guardAllows(suggestionsShownAt[replyID] ?? clock.now)
        else { return false }
        switch action.suggest {
        case .oneClick:
            pendingSuggestion = nil
            action.run()
            return true
        case .confirm:
            pendingSuggestion = PendingSuggestion(replyID: replyID, id: id, shownAt: clock.now)
            return true
        case .never:
            return false
        }
    }

    /// The confirm's Start, Stop or Restart: resolved once more, then run, with the toast
    /// "Started Web dev server". False when it was ignored (F6, S2) or the action is gone.
    @discardableResult
    public func confirmSuggested() -> Bool {
        guard let pending = pendingSuggestion, guardAllows(pending.shownAt) else { return false }
        pendingSuggestion = nil
        guard let action = actions.resolve(pending.id), case .confirm(let confirmation) = action.suggest else {
            return false
        }
        action.run()
        toaster?.toast(
            Strings.SuggestedActions.done(verb: confirmation.verb, name: sanitizeForDisplay(confirmation.name, max: 64))
        )
        return true
    }

    /// The confirm's Cancel: the buttons come back, and wait 600 ms again (F6).
    public func cancelSuggested() {
        guard let pending = pendingSuggestion else { return }
        pendingSuggestion = nil
        suggestionsShownAt[pending.replyID] = clock.now
    }

    /// A loaded pin keeps only the suggestions that resolve now (F1); its rows take input
    /// 600 ms after it shows.
    func dropUnresolvedSuggestions() {
        items = items.map { item in
            guard case .message(var message) = item, !message.suggested.isEmpty else { return item }
            // An action that exists but doesn't apply now stays, shown disabled with why, as in a
            // live chat; anything else is dropped (Rev 7).
            message.suggested = message.suggested.filter {
                actions.resolve($0) != nil || actions.unavailable($0) != nil
            }
            return .message(message)
        }
        let now = clock.now
        for reply in replies() where !reply.suggested.isEmpty { suggestionsShownAt[reply.id] = now }
    }
}
