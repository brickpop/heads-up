import Foundation

/// A pinned chat as it is kept (ADR-001 §6.3): its messages in order and their images. Problem
/// rows and tool results aren't kept.
public struct PinnedChat: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let modelName: String
    public let pinnedAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    /// The messages' images, by id.
    public var images: [String: ProcessedImage]
}

/// One row of the Pinned list, without its messages.
public struct PinnedSummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let modelName: String
    public let pinnedAt: Date
    public let messageCount: Int
}

/// Where pinned chats are kept. The chat calls it as the user pins, follows up and unpins.
@MainActor
public protocol PinnedChats: AnyObject {
    /// Most recently pinned first.
    func list() throws(PinnedChatsError) -> [PinnedSummary]
    func load(_ id: String) throws(PinnedChatsError) -> PinnedChat?
    /// Writes the chat whole, in one transaction: its row, its messages, and its images not yet kept.
    func save(_ chat: PinnedChat) throws(PinnedChatsError)
    /// Deletes the chat with its messages and images, leaving nothing of them in the file (F12).
    func delete(_ id: String) throws(PinnedChatsError)
}

public struct PinnedChatsError: Error, Equatable, Sendable {
    public let message: String
}

/// The title rule (ADR-001 §6.3): the first user message on one line, cleaned (F16), cut to
/// 47 characters and "…"; "Image conversation" when it has only images. It counts Unicode
/// scalars, as SQLite's `length()` does, so the 48-character CHECK always holds, emoji included.
enum PinnedTitle {
    static let maxLength = 48

    static func make(_ messages: [ChatMessage]) -> String {
        let first = messages.first { $0.role == .user }?.text ?? ""
        let words = sanitizeForDisplay(first, max: 0).split(whereSeparator: \.isWhitespace)
        let text = words.joined(separator: " ")
        guard !text.isEmpty else { return Strings.Chat.imageConversation }
        guard text.unicodeScalars.count > maxLength else { return text }
        var cut = ""
        var scalars = 0
        for character in text {
            let size = character.unicodeScalars.count
            guard scalars + size <= maxLength - 1 else { break }
            cut.append(character)
            scalars += size
        }
        return cut + "…"
    }
}

/// Pinned chats in headsup.sqlite. The file is created at the first pin, so a fresh install
/// writes nothing. Each connection has `secure_delete` on, and an unpin is followed by a WAL
/// checkpoint, so an unpinned chat survives neither in free pages nor in the WAL (F12).
public final class SQLitePinnedChats: PinnedChats {
    private let file: URL
    private var database: Database?

    public init(folder: URL) {
        file = folder.appendingPathComponent(Database.fileName)
    }

    public func list() throws(PinnedChatsError) -> [PinnedSummary] {
        guard let database = try existing() else { return [] }
        let rows = try run { () throws(Database.Failure) in
            try database.query(
                """
                SELECT chat.id, chat.title, chat.model_name, chat.pinned_at, COUNT(message.seq)
                FROM chat LEFT JOIN message ON message.chat_id = chat.id
                GROUP BY chat.id ORDER BY chat.pinned_at DESC, chat.id DESC
                """)
        }
        return rows.compactMap { row in
            guard case .text(let id) = row[0], case .text(let title) = row[1], case .text(let model) = row[2],
                case .integer(let pinned) = row[3], case .integer(let count) = row[4]
            else { return nil }
            return PinnedSummary(
                id: id, title: title, modelName: model, pinnedAt: Date(milliseconds: pinned), messageCount: Int(count))
        }
    }

    public func load(_ id: String) throws(PinnedChatsError) -> PinnedChat? {
        guard let database = try existing() else { return nil }
        let chats = try run { () throws(Database.Failure) in
            try database.query("SELECT title, model_name, pinned_at, updated_at FROM chat WHERE id = ?", [.text(id)])
        }
        guard let row = chats.first, case .text(let title) = row[0], case .text(let model) = row[1],
            case .integer(let pinned) = row[2], case .integer(let updated) = row[3]
        else { return nil }
        let bodies = try run { () throws(Database.Failure) in
            try database.query("SELECT body FROM message WHERE chat_id = ? ORDER BY seq", [.text(id)])
        }
        // A message or image that can't be read fails the whole load: a chat with a hole in it
        // would be shown, then saved back without the hole's message (Rev 5).
        let decoder = JSONDecoder()
        var messages: [ChatMessage] = []
        for row in bodies {
            guard case .text(let body) = row[0],
                let message = try? decoder.decode(ChatMessage.self, from: Data(body.utf8))
            else { throw Self.unreadable }
            messages.append(message)
        }
        let imageRows = try run { () throws(Database.Failure) in
            try database.query("SELECT id, mime, bytes FROM image WHERE chat_id = ?", [.text(id)])
        }
        var images: [String: ProcessedImage] = [:]
        for row in imageRows {
            guard case .text(let imageID) = row[0], case .text(let mimeText) = row[1],
                let mime = ProcessedImage.MIME(rawValue: mimeText), case .blob(let data) = row[2]
            else { throw Self.unreadable }
            // No preview is kept: the chat makes one when it loads (Rev 4).
            images[imageID] = ProcessedImage(data: data, mime: mime, pixelWidth: 0, pixelHeight: 0, preview: Data())
        }
        return PinnedChat(
            id: id, title: title, modelName: model, pinnedAt: Date(milliseconds: pinned),
            updatedAt: Date(milliseconds: updated), messages: messages, images: images)
    }

    public func save(_ chat: PinnedChat) throws(PinnedChatsError) {
        let database = try opened()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try run { () throws(Database.Failure) in
            try database.transaction { () throws(Database.Failure) in
                try database.execute(
                    """
                    INSERT INTO chat (id, title, model_name, pinned_at, updated_at) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at
                    """,
                    [
                        .text(chat.id), .text(chat.title), .text(chat.modelName),
                        .integer(chat.pinnedAt.milliseconds), .integer(chat.updatedAt.milliseconds),
                    ])
                try database.execute("DELETE FROM message WHERE chat_id = ?", [.text(chat.id)])
                for (seq, message) in chat.messages.enumerated() {
                    let body = (try? encoder.encode(message)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    try database.execute(
                        "INSERT INTO message (chat_id, seq, body) VALUES (?, ?, ?)",
                        [.text(chat.id), .integer(Int64(seq)), .text(body)])
                }
                // Images don't change: only new ones are written, and ones no message uses go.
                let used = Set(chat.messages.flatMap(\.imageIDs))
                for (id, image) in chat.images where used.contains(id) {
                    try database.execute(
                        "INSERT OR IGNORE INTO image (id, chat_id, mime, bytes) VALUES (?, ?, ?, ?)",
                        [.text(id), .text(chat.id), .text(image.mime.rawValue), .blob(image.data)])
                }
                let kept = try database.query("SELECT id FROM image WHERE chat_id = ?", [.text(chat.id)])
                for row in kept {
                    if case .text(let id) = row[0], !used.contains(id) {
                        try database.execute("DELETE FROM image WHERE id = ?", [.text(id)])
                    }
                }
            }
        }
    }

    public func delete(_ id: String) throws(PinnedChatsError) {
        guard let database = try existing() else { return }
        try run { () throws(Database.Failure) in
            try database.execute("DELETE FROM chat WHERE id = ?", [.text(id)])
            // secure_delete zeroed the freed pages; the checkpoint empties the WAL too (F12).
            try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// The database, if the file exists; never creates it.
    private func existing() throws(PinnedChatsError) -> Database? {
        if let database { return database }
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try opened()
    }

    /// The database, created if needed.
    private func opened() throws(PinnedChatsError) -> Database {
        if let database { return database }
        let database = try run { () throws(Database.Failure) in try Database(file: file) }
        self.database = database
        return database
    }

    static let unreadable = PinnedChatsError(message: "the saved chat can't be read")

    private func run<T>(_ body: () throws(Database.Failure) -> T) throws(PinnedChatsError) -> T {
        do {
            return try body()
        } catch {
            throw PinnedChatsError(message: error.message)
        }
    }
}

/// Pinned chats for this run only: previews, and tests that don't need the file.
public final class MemoryPinnedChats: PinnedChats {
    private var chats: [String: PinnedChat] = [:]

    public init() {}

    public func list() throws(PinnedChatsError) -> [PinnedSummary] {
        chats.values.sorted { ($0.pinnedAt, $0.id) > ($1.pinnedAt, $1.id) }.map {
            PinnedSummary(
                id: $0.id, title: $0.title, modelName: $0.modelName, pinnedAt: $0.pinnedAt,
                messageCount: $0.messages.count)
        }
    }

    public func load(_ id: String) throws(PinnedChatsError) -> PinnedChat? { chats[id] }
    public func save(_ chat: PinnedChat) throws(PinnedChatsError) { chats[chat.id] = chat }
    public func delete(_ id: String) throws(PinnedChatsError) { chats[id] = nil }
}

extension Date {
    var milliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init(milliseconds: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}

#if DEBUG
    /// Pinned chats in memory that fail on demand, for the failed-save tests.
    public final class FakePinnedChats: PinnedChats {
        private let memory = MemoryPinnedChats()
        /// Every call fails with this while it is set.
        public var failure: PinnedChatsError?

        public init() {}

        public func list() throws(PinnedChatsError) -> [PinnedSummary] {
            if let failure { throw failure }
            return try memory.list()
        }
        public func load(_ id: String) throws(PinnedChatsError) -> PinnedChat? {
            if let failure { throw failure }
            return try memory.load(id)
        }
        public func save(_ chat: PinnedChat) throws(PinnedChatsError) {
            if let failure { throw failure }
            try memory.save(chat)
        }
        public func delete(_ id: String) throws(PinnedChatsError) {
            if let failure { throw failure }
            try memory.delete(id)
        }
    }
#endif
