import CSQLite
import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// headsup.sqlite (ADR-001 §6.3): a thin wrapper over the system SQLite.
///
/// - The file is created 0600 with `open(2)` before SQLite opens it, so it is never readable
///   by others, even for a moment; SQLite gives its `-wal` and `-shm` files the same mode (S1).
/// - Each connection turns on foreign keys, WAL and `secure_delete` (F12).
/// - Migrations are an ordered list of SQL counted by `user_version`, applied in one
///   transaction. A database from a newer HeadsUp is not opened.
public final class Database {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// A value bound to, or read from, a statement.
    public enum Value: Equatable, Sendable {
        case integer(Int64)
        case text(String)
        /// Bytes, such as an image (Scan I6): never read as text, which would stop at a zero byte.
        case blob(Data)
        case null
    }

    public static let fileName = "headsup.sqlite"

    /// The schema, one entry per version. Nick owns it; append, never edit an applied one.
    static let migrations = [
        """
        CREATE TABLE chat (id TEXT PRIMARY KEY, title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 48),
          model_name TEXT NOT NULL, pinned_at INTEGER NOT NULL, updated_at INTEGER NOT NULL) STRICT;
        CREATE TABLE message (chat_id TEXT NOT NULL REFERENCES chat(id) ON DELETE CASCADE,
          seq INTEGER NOT NULL CHECK (seq >= 0), body TEXT NOT NULL CHECK (json_valid(body)),
          PRIMARY KEY (chat_id, seq)) STRICT, WITHOUT ROWID;
        CREATE TABLE image (id TEXT PRIMARY KEY, chat_id TEXT NOT NULL REFERENCES chat(id) ON DELETE CASCADE,
          mime TEXT NOT NULL CHECK (mime IN ('image/jpeg','image/png')), bytes BLOB NOT NULL) STRICT;
        CREATE TABLE focus_day (day TEXT PRIMARY KEY, sessions INTEGER NOT NULL DEFAULT 0 CHECK (sessions >= 0),
          minutes INTEGER NOT NULL DEFAULT 0 CHECK (minutes >= 0)) STRICT;
        """
    ]

    private var handle: OpaquePointer?

    /// Opens (creating if needed) the database at `file`, and brings its schema up to date.
    public init(file: URL) throws(Failure) {
        do {
            try SecureFile.makeFolder(file.deletingLastPathComponent())
        } catch {
            throw Failure(message: error.description)
        }
        try Self.createPrivately(file)
        for suffix in ["-wal", "-shm"] {
            try Self.checkCompanion(URL(fileURLWithPath: file.path + suffix))
        }

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(file.path, &opened, flags, nil) == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(opened)
            throw Failure(message: "open \(file.path): \(message)")
        }
        handle = opened
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA secure_delete = ON")
            try migrate()
        } catch {
            sqlite3_close(opened)
            handle = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Creates the file with mode 0600 if it is missing; checks an existing one is a regular
    /// file, not a link, and narrows it to 0600 if it is wider.
    private static func createPrivately(_ file: URL) throws(Failure) {
        let fd = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure(message: "open \(file.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw Failure(message: "\(file.path) is not a regular file")
        }
        if info.st_mode & 0o777 != 0o600, fchmod(fd, 0o600) != 0 {
            throw Failure(message: "chmod \(file.path): \(String(cString: strerror(errno)))")
        }
    }

    /// SQLite's `-wal` and `-shm` files, if they exist from an earlier run (Scan I5): each must be
    /// a regular file, not a link, and is narrowed to 0600 if it is wider.
    private static func checkCompanion(_ file: URL) throws(Failure) {
        var info = stat()
        if lstat(file.path, &info) != 0 {
            if errno == ENOENT { return }
            throw Failure(message: "lstat \(file.path): \(String(cString: strerror(errno)))")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw Failure(message: "\(file.path) is not a regular file")
        }
        if info.st_mode & 0o777 != 0o600, chmod(file.path, 0o600) != 0 {
            throw Failure(message: "chmod \(file.path): \(String(cString: strerror(errno)))")
        }
    }

    // MARK: Schema

    /// The schema version the file has.
    public func version() throws(Failure) -> Int {
        guard case .integer(let version) = try query("PRAGMA user_version").first?.first else { return 0 }
        return Int(version)
    }

    private func migrate() throws(Failure) {
        let current = try version()
        guard current <= Self.migrations.count else {
            throw Failure(message: "headsup.sqlite has schema \(current), newer than this HeadsUp knows")
        }
        guard current < Self.migrations.count else { return }
        try transaction { () throws(Failure) in
            for sql in Self.migrations[current...] {
                try execute(sql)
            }
            try execute("PRAGMA user_version = \(Self.migrations.count)")
        }
    }

    // MARK: Statements

    /// Runs `body` in one transaction: all of it is written, or none of it.
    public func transaction(_ body: () throws(Failure) -> Void) throws(Failure) {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs SQL that returns no rows. Several statements are allowed only without parameters.
    public func execute(_ sql: String, _ parameters: [Value] = []) throws(Failure) {
        if parameters.isEmpty {
            var message: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(handle, sql, nil, nil, &message) != SQLITE_OK {
                let text = message.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(message)
                throw Failure(message: text)
            }
            return
        }
        _ = try query(sql, parameters)
    }

    /// Runs one statement and returns its rows.
    public func query(_ sql: String, _ parameters: [Value] = []) throws(Failure) -> [[Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure(message: lastError)
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in parameters.enumerated() {
            let position = Int32(index + 1)
            let status: Int32 =
                switch value {
                case .integer(let number): sqlite3_bind_int64(statement, position, number)
                case .text(let text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
                case .blob(let data):
                    data.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(bytes.count), Self.transient)
                    }
                case .null: sqlite3_bind_null(statement, position)
                }
            guard status == SQLITE_OK else { throw Failure(message: lastError) }
        }

        var rows: [[Value]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw Failure(message: lastError) }
            rows.append(
                (0..<sqlite3_column_count(statement)).map { column in
                    switch sqlite3_column_type(statement, column) {
                    case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, column))
                    case SQLITE_NULL: .null
                    case SQLITE_BLOB:
                        .blob(
                            sqlite3_column_blob(statement, column).map {
                                Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, column)))
                            } ?? Data())
                    default: .text(String(cString: sqlite3_column_text(statement, column)))
                    }
                })
        }
    }

    private var lastError: String {
        String(cString: sqlite3_errmsg(handle))
    }

    /// SQLite copies bound text at once (SQLITE_TRANSIENT).
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
