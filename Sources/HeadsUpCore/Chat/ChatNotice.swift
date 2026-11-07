import Foundation

/// The notification when a reply ends while the HUD is hidden (Chat spec; card chat-notify):
/// "Reply ready", the approval card's own title while one waits, or "Reply failed". It never
/// holds the reply's text. There is one at a time, under one id: a new one replaces the last.
/// It goes when the user opens the HUD on its chat, when the next reply starts, or when its
/// chat is gone: an unpinned chat cleared, or its pin unpinned or deleted.
extension ChatStore {
    static let notificationID = "chat.reply"

    /// The chat a notification belongs to: the pinned chat's id, or nil for the unpinned one.
    struct Notice: Equatable {
        let pinID: String?
    }

    /// How the reply ended.
    enum ReplyEnd: Equatable {
        case ready(model: String)
        case failed
    }

    /// The reply ended: posts its notification, unless the HUD is open.
    func notifyReplyEnded(_ end: ReplyEnd) {
        switch end {
        case .ready(let model):
            postNotice(title: Strings.Chat.replyReadyTitle, body: model)
        case .failed:
            postNotice(title: Strings.Chat.replyFailedTitle, body: Strings.Chat.replyFailedBody)
        }
    }

    /// A card waits for the user: posts its own title, "<model> wants to read your clipboard",
    /// unless the HUD is open.
    func notifyToolAsk(_ card: PendingCard) {
        postNotice(
            title: Strings.Tools.cardTitle(card.model, card.tool, timer: card.timer), body: Strings.Chat.toolAskBody)
    }

    /// The HUD shows the conversation: its notification goes if it belongs to this chat.
    public func conversationShown() {
        guard let notice, notice.pinID == pinnedID else { return }
        withdrawNotice()
    }

    /// The pinned chat the notification belongs to, for a click on it; nil for the unpinned one.
    var noticePinID: String? { notice?.pinID }

    /// Removes the notification, pending or shown. AppModel also calls it at launch: one left from
    /// the last run points to a chat that isn't known any more.
    func removeLeftoverNotice() {
        notifier.cancelPending(id: Self.notificationID)
        notifier.removeDelivered(id: Self.notificationID)
    }

    func withdrawNotice() {
        guard notice != nil else { return }
        notice = nil
        removeLeftoverNotice()
    }

    private func postNotice(title: String, body: String) {
        guard navigator?.isOpen != true else { return }
        notice = Notice(pinID: pinnedID)
        notifier.schedule(
            NotificationRequest(
                id: Self.notificationID, category: .chatReply, title: title, body: body, date: clock.now))
    }
}
