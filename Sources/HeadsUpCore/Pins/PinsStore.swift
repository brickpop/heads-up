import Foundation
import Observation

/// How the chat keeps its pinned copy: one narrow protocol, so the chat never holds the list
/// (contract rule 3, as with `Toaster` and `HUDChat`).
@MainActor
protocol PinSaving: AnyObject {
    func save(_ chat: PinnedChat) throws(PinnedChatsError)
    func delete(_ id: String) throws(PinnedChatsError)
}

/// The pinned chats (Pinned chats spec; ADR-001 §6.3): the list, its screen, unpinning from
/// it, and loading one. The chat pins and saves through `PinSaving`.
@MainActor
@Observable
public final class PinsStore: PinSaving {
    /// The Pinned list, most recently pinned first.
    public private(set) var summaries: [PinnedSummary] = []
    /// What went wrong with the list, until the next success.
    private(set) var listProblem: ListProblem?

    enum ListProblem: Equatable {
        /// The list couldn't be read: Try Again reads it again.
        case read(reason: String?)
        /// One chat couldn't be opened.
        case open(reason: String?)
        /// One chat couldn't be unpinned.
        case unpin(reason: String?)
    }

    @ObservationIgnored private let store: PinnedChats
    @ObservationIgnored private let clock: Clock
    /// The pin the chat on screen is linked to, for the highlighted row. AppModel sets it.
    @ObservationIgnored var loadedID: @MainActor () -> String? = { nil }
    /// A pin was deleted from the list: the chat unlinks it if it was its own. AppModel sets it.
    @ObservationIgnored var didDelete: @MainActor (_ id: String) -> Void = { _ in }

    init(store: PinnedChats, clock: Clock) {
        self.store = store
        self.clock = clock
        refresh()
    }

    /// How many chats are pinned, for the menu bar row and the Pinned chats action.
    public var count: Int { summaries.count }

    /// Try Again, on "Couldn't read your pinned chats": reads the list again.
    public func retry() {
        refresh()
    }

    /// Reads the list again.
    func refresh() {
        do {
            summaries = try store.list()
            listProblem = nil
        } catch {
            summaries = []
            listProblem = .read(reason: error.reason)
        }
    }

    /// One pinned chat, whole. A chat that is gone refreshes the list; one that can't be read
    /// shows why on the list, and nothing of it is shown.
    func open(_ id: String) -> PinnedChat? {
        do {
            guard let chat = try store.load(id) else {
                refresh()
                return nil
            }
            listProblem = nil
            return chat
        } catch {
            listProblem = .open(reason: error.reason)
            return nil
        }
    }

    /// The × on a row: deletes the chat, leaving nothing of it in the database (F12). If the
    /// chat on screen was this one, it stays there, not kept.
    public func unpin(_ id: String) {
        do {
            try delete(id)
        } catch {
            listProblem = .unpin(reason: error.reason)
            return
        }
        didDelete(id)
    }

    // MARK: PinSaving

    func save(_ chat: PinnedChat) throws(PinnedChatsError) {
        try store.save(chat)
        refresh()
    }

    func delete(_ id: String) throws(PinnedChatsError) {
        try store.delete(id)
        refresh()
    }

    // MARK: The screen

    private var problemScreen: PinnedListScreen.Problem? {
        switch listProblem {
        case .read(let reason):
            PinnedListScreen.Problem(text: Strings.Chat.pinnedListFailed(reason), retry: Strings.Chat.tryAgainTitle)
        case .open(let reason): PinnedListScreen.Problem(text: Strings.Chat.openFailed(reason), retry: nil)
        case .unpin(let reason): PinnedListScreen.Problem(text: Strings.Chat.unpinFailed(reason), retry: nil)
        case nil: nil
        }
    }

    /// The Pinned list.
    public var screen: PinnedListScreen {
        let now = clock.now
        let loaded = loadedID()
        return PinnedListScreen(
            label: Strings.Chat.pinnedChats, back: Strings.Chat.backToChat,
            empty: summaries.isEmpty ? Strings.Chat.nothingPinned : nil, problem: problemScreen,
            rows: summaries.map { summary in
                let title = sanitizeForDisplay(summary.title, max: PinnedTitle.maxLength)
                let meta = Strings.Chat.pinnedMeta(
                    messages: summary.messageCount, model: sanitizeForDisplay(summary.modelName, max: 64))
                let date = Strings.Chat.pinnedDate(summary.pinnedAt, now: now)
                return PinnedListScreen.Row(
                    id: summary.id, title: title, meta: meta, date: date, isLoaded: summary.id == loaded,
                    unpinHelp: Strings.Chat.unpin(title),
                    accessibilityLabel: Strings.Chat.pinnedRowLabel(title: title, meta: meta, date: date))
            })
    }
}

/// The Pinned list, ready to draw (Pinned chats spec).
public struct PinnedListScreen: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        /// "4 messages · GPT-4o mini"
        public let meta: String
        /// "Just now", "Yesterday", "Oct 21"
        public let date: String
        /// The chat on screen is this one.
        public let isLoaded: Bool
        /// "Unpin Weekly plan", the ×'s tooltip and VoiceOver label.
        public let unpinHelp: String
        public let accessibilityLabel: String
    }

    /// "Pinned chats"
    public let label: String
    /// "Back to chat"
    public let back: String
    /// The empty state, when nothing is pinned.
    public let empty: String?
    /// The list couldn't be read, a chat couldn't be opened, or a row couldn't be unpinned: a
    /// --danger line.
    public let problem: Problem?

    public struct Problem: Equatable, Sendable {
        public let text: String
        /// "Try Again", only when the list couldn't be read: `pins.retry()`.
        public let retry: String?
    }
    /// Most recently pinned first.
    public let rows: [Row]
}

extension PinnedChatsError {
    /// The reason in plain words for Yuki's lines, or nil when there is none worth showing.
    var reason: String? {
        let text = message.lowercased()
        if text.contains("disk is full") || text.contains("database or disk is full") { return "the disk is full" }
        if text.contains("readonly") || text.contains("read-only") { return "the file can't be written" }
        if text.contains("can't be read") || text.contains("not a database") || text.contains("malformed") {
            return "the saved chat can't be read"
        }
        return nil
    }
}
