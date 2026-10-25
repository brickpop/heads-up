import Foundation

/// The pinned chat a conversation is linked to: follow-ups update it.
struct PinLink: Equatable, Sendable {
    let id: String
    let title: String
    let modelName: String
    let pinnedAt: Date
}

/// A pin, a save or an unpin that failed (Pinned chats spec, "When saving fails"), until the
/// next success, ⌘N or loading another chat. Never a toast.
enum PinProblem: Equatable, Sendable {
    case pin(reason: String?)
    case save(reason: String?)
    case unpin(reason: String?)
}

/// The toolbar's failed-save line: a --danger ×, the text, and a ghost Try Again.
public struct PinProblemScreen: Equatable, Sendable {
    public let text: String
    /// "Try Again": `chat.retryPin()`.
    public let tryAgain: String
}

extension ChatStore {
    /// A pinned chat is written at most this often while a reply streams.
    static let pinSaveInterval: TimeInterval = 0.5

    /// The conversation is pinned.
    public var isPinned: Bool { pin != nil }

    /// The pin the conversation is linked to, for the Pinned list's highlighted row.
    var pinnedID: String? { pin?.id }

    /// Pin or Unpin, also ⌘P. Pinning needs a message from the user; it keeps the chat now and
    /// links it, so follow-ups update the stored copy. Unpinning deletes the stored copy; the
    /// chat stays on screen, not kept.
    public func togglePin() {
        if let pin {
            unpin(pin.id)
            return
        }
        let messages = storedMessages
        guard messages.contains(where: { $0.role == .user }) else { return }
        let now = clock.now
        let link = PinLink(
            id: UUID().uuidString, title: PinnedTitle.make(messages),
            modelName: endpoints.active?.name ?? messages.last(where: { $0.model != nil })?.model ?? "",
            pinnedAt: now)
        do {
            try pins.save(stored(link, messages: messages, at: now))
        } catch {
            pinProblem = .pin(reason: error.reason)
            return
        }
        pin = link
        lastPinSave = now
        pinProblem = nil
        toaster?.toast(Strings.Chat.chatPinned)
    }

    /// Unpin on the chat: deletes the stored copy, leaving nothing of it in the database (F12).
    private func unpin(_ id: String) {
        do {
            try pins.delete(id)
        } catch {
            pinProblem = .unpin(reason: error.reason)
            return
        }
        pinDeleted(id)
        toaster?.toast(Strings.Chat.chatUnpinned)
    }

    /// The pin was deleted (here or from the Pinned list): if it was this chat's, the chat stays
    /// on screen, not kept.
    func pinDeleted(_ id: String) {
        guard pin?.id == id else { return }
        pin = nil
        pinProblem = nil
        pinSave?.cancel()
        pinSave = nil
    }

    /// Try Again, on the failed-save line.
    public func retryPin() {
        switch pinProblem {
        case .pin: togglePin()
        case .save: savePin()
        case .unpin: if let pin { unpin(pin.id) }
        case nil: break
        }
    }

    /// The failed-save line, or nil.
    var pinProblemScreen: PinProblemScreen? {
        guard let pinProblem else { return nil }
        let text =
            switch pinProblem {
            case .pin(let reason): Strings.Chat.pinFailed(reason)
            case .save(let reason): Strings.Chat.saveFailed(reason)
            case .unpin(let reason): Strings.Chat.unpinFailed(reason)
            }
        return PinProblemScreen(text: text, tryAgain: Strings.Chat.tryAgainTitle)
    }

    /// Replaces the conversation with a pinned chat, linked to it (`AppModel.loadPinned` stops
    /// a running reply first). A reply that was still streaming when it was kept shows as
    /// stopped. The active model stays as it is. Thumbnails come later, through `setPreviews`.
    func restore(_ stored: PinnedChat) {
        stop()
        clearConversation()
        items = stored.messages.map { message in
            var message = message
            if message.state == .streaming { message.state = .stopped }
            return .message(message)
        }
        images = stored.images
        pin = PinLink(id: stored.id, title: stored.title, modelName: stored.modelName, pinnedAt: stored.pinnedAt)
        lastPinSave = clock.now
    }

    /// The 240 × 160 thumbnails of a loaded chat's images, made once after it loaded.
    func setPreviews(_ made: [String: Data]) {
        for (id, preview) in made where images[id] != nil {
            previews[id] = preview
        }
    }

    // MARK: Keeping a pinned chat up to date

    /// Writes the pinned chat now, if there is one. A failure shows the failed-save line; the
    /// next change tries again.
    func savePin() {
        pinSave?.cancel()
        pinSave = nil
        guard let pin else { return }
        let now = clock.now
        lastPinSave = now
        do {
            try pins.save(stored(pin, messages: storedMessages, at: now))
            if case .save = pinProblem { pinProblem = nil }
        } catch {
            pinProblem = .save(reason: error.reason)
        }
    }

    /// While a reply streams: writes the pinned chat at most every 500 ms.
    func savePinSoon() {
        guard pin != nil, pinSave == nil else { return }
        let due = (lastPinSave ?? .distantPast).addingTimeInterval(Self.pinSaveInterval)
        if clock.now >= due {
            savePin()
        } else {
            pinSave = scheduler.schedule(at: due) { [weak self] in
                self?.pinSave = nil
                self?.savePin()
            }
        }
    }

    /// The messages a pin keeps: what the user wrote and what the model answered, without the
    /// rows, the tool results, or replies with no text yet (a step that only asked for tools).
    private var storedMessages: [ChatMessage] {
        items.compactMap { item in
            guard case .message(let message) = item else { return nil }
            if message.role == .assistant && message.text.isEmpty { return nil }
            return message
        }
    }

    private func stored(_ link: PinLink, messages: [ChatMessage], at now: Date) -> PinnedChat {
        let ids = Set(messages.flatMap(\.imageIDs))
        return PinnedChat(
            id: link.id, title: link.title, modelName: link.modelName, pinnedAt: link.pinnedAt, updatedAt: now,
            messages: messages, images: images.filter { ids.contains($0.key) })
    }
}
