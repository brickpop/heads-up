import Foundation
import Testing

@testable import HeadsUpCore

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

private func temporaryFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("headsup-db-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func mode(_ path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
}

// Serialized: one test changes the process umask.
@MainActor
@Suite(.serialized) struct DatabaseTests {
    @Test func theFileAndItsWALAre0600EvenWithALooseUmask() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("HeadsUp")
        let previous = umask(0o022)
        defer { umask(previous) }

        let database = try Database(file: folder.appendingPathComponent(Database.fileName))
        try database.execute("INSERT INTO focus_day (day, sessions, minutes) VALUES ('2026-10-25', 1, 25)")

        #expect(try mode(folder.path) == 0o700)
        #expect(try mode(folder.appendingPathComponent("headsup.sqlite").path) == 0o600)
        #expect(try mode(folder.appendingPathComponent("headsup.sqlite-wal").path) == 0o600)
    }

    @Test func anExistingFileOthersCanReadIsNarrowedTo0600() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(Database.fileName)
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        chmod(file.path, 0o644)
        _ = try Database(file: file)
        #expect(try mode(file.path) == 0o600)
    }

    @Test func migrationOneCreatesTheSchemaAndRunsOnce() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(Database.fileName)
        do {
            let database = try Database(file: file)
            #expect(try database.version() == 1)
            try database.execute("INSERT INTO focus_day (day, sessions, minutes) VALUES ('2026-10-25', 2, 50)")
        }
        let reopened = try Database(file: file)
        #expect(try reopened.version() == 1)
        #expect(try reopened.query("SELECT sessions FROM focus_day") == [[.integer(2)]])
        // The pragmas hold on each connection.
        #expect(try reopened.query("PRAGMA foreign_keys") == [[.integer(1)]])
        #expect(try reopened.query("PRAGMA secure_delete") == [[.integer(1)]])
        #expect(try reopened.query("PRAGMA journal_mode") == [[.text("wal")]])
    }

    @Test func theSchemaChecksHold() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try Database(file: root.appendingPathComponent(Database.fileName))
        #expect(throws: Database.Failure.self) {
            try database.execute("INSERT INTO focus_day (day, sessions) VALUES ('2026-10-25', -1)")
        }
        #expect(throws: Database.Failure.self) {
            try database.execute("INSERT INTO message (chat_id, seq, body) VALUES ('missing', 0, '{}')")
        }
    }

    @Test func aDatabaseFromANewerHeadsUpIsNotOpened() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(Database.fileName)
        do {
            let database = try Database(file: file)
            try database.execute("PRAGMA user_version = 7")
        }
        #expect(throws: Database.Failure.self) { _ = try Database(file: file) }
    }

    @Test func aLinkInPlaceOfTheFileIsRefused() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appendingPathComponent("elsewhere.sqlite")
        _ = FileManager.default.createFile(atPath: elsewhere.path, contents: nil)
        let file = root.appendingPathComponent(Database.fileName)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        #expect(throws: Database.Failure.self) { _ = try Database(file: file) }
    }

    @Test func aFailedTransactionWritesNothing() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try Database(file: root.appendingPathComponent(Database.fileName))
        #expect(throws: Database.Failure.self) {
            try database.transaction { () throws(Database.Failure) in
                try database.execute("INSERT INTO focus_day (day, sessions) VALUES ('2026-10-25', 1)")
                try database.execute("INSERT INTO focus_day (day, sessions) VALUES ('2026-10-25', 1)")  // duplicate key
            }
        }
        #expect(try database.query("SELECT count(*) FROM focus_day") == [[.integer(0)]])
    }
}

@MainActor
@Suite struct FocusHistoryTests {
    @Test func aFreshInstallCreatesNoDatabaseUntilASessionCompletes() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("HeadsUp")
        let history = SQLiteFocusHistory(folder: folder, today: "2026-10-25")
        #expect(history.day("2026-10-25") == FocusDay())
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        history.recordSession(minutes: 25, day: "2026-10-25")
        history.recordSession(minutes: 50, day: "2026-10-25")
        #expect(history.day("2026-10-25") == FocusDay(sessions: 2, minutes: 75))
        #expect(history.lastError == nil)

        let next = SQLiteFocusHistory(folder: folder, today: "2026-10-25")
        #expect(next.day("2026-10-25") == FocusDay(sessions: 2, minutes: 75))
        #expect(next.day("2026-10-26") == FocusDay())
    }

    @Test func daysOlderThanAWeekAreDeletedAtLaunch() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = SQLiteFocusHistory(folder: root, today: "2026-10-25")
        for day in ["2026-10-10", "2026-10-17", "2026-10-18", "2026-10-25"] {
            history.recordSession(minutes: 25, day: day)
        }
        let later = SQLiteFocusHistory(folder: root, today: "2026-10-25")
        #expect(later.day("2026-10-10") == FocusDay())
        #expect(later.day("2026-10-17") == FocusDay())
        #expect(later.day("2026-10-18").sessions == 1)
        #expect(SQLiteFocusHistory.cutoff(today: "2026-03-03") == "2026-02-24")
    }

    @Test func whenTheDatabaseCantBeUsedCountsStayInMemory() throws {
        let root = try temporaryFolder()
        defer {
            chmod(root.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        chmod(root.path, 0o500)  // the file can't be created
        let history = SQLiteFocusHistory(folder: root, today: "2026-10-25")
        history.recordSession(minutes: 25, day: "2026-10-25")
        #expect(history.day("2026-10-25") == FocusDay(sessions: 1, minutes: 25))
        #expect(history.lastError != nil)
    }

    @Test func daysAreLocalCalendarDates() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_761_350_400)  // 2025-10-25 00:00 UTC
        #expect(FocusDayFormat.string(date, timeZone: utc) == "2025-10-25")
        #expect(FocusDayFormat.string(date, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == "2025-10-24")
    }
}

@MainActor
@Suite struct DatabaseCompanionTests {
    @Test func aWideWALFromAnEarlierRunIsNarrowed() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(Database.fileName)
        _ = try Database(file: file)
        let wal = root.appendingPathComponent("headsup.sqlite-wal")
        _ = FileManager.default.createFile(atPath: wal.path, contents: nil)
        chmod(wal.path, 0o644)
        // Checked while open: SQLite deletes an empty -wal when the last connection closes.
        let reopened = try Database(file: file)
        #expect(try mode(wal.path) == 0o600)
        withExtendedLifetime(reopened) {}
    }

    @Test func aLinkInPlaceOfTheWALIsRefused() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(Database.fileName)
        _ = try Database(file: file)
        let elsewhere = root.appendingPathComponent("elsewhere")
        _ = FileManager.default.createFile(atPath: elsewhere.path, contents: nil)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("headsup.sqlite-shm"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("headsup.sqlite-shm"), withDestinationURL: elsewhere)
        #expect(throws: Database.Failure.self) { _ = try Database(file: file) }
    }
}

/// Scan I6: bytes go in and come out whole, zero bytes included.
@Suite struct DatabaseBlobTests {
    @Test func blobsRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("headsup-blob-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try Database(file: folder.appendingPathComponent("headsup.sqlite"))
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0xFF, 0x00, 0x41])
        try database.execute("INSERT INTO chat VALUES ('c', 'T', 'M', 1, 1)", [])
        try database.execute(
            "INSERT INTO image VALUES (?, ?, ?, ?)", [.text("i"), .text("c"), .text("image/png"), .blob(bytes)])
        let rows = try database.query("SELECT bytes FROM image WHERE id = ?", [.text("i")])
        #expect(rows.first?.first == .blob(bytes))
        try database.execute(
            "INSERT INTO image VALUES (?, ?, ?, ?)", [.text("e"), .text("c"), .text("image/png"), .blob(Data())])
        #expect(try database.query("SELECT bytes FROM image WHERE id = 'e'").first?.first == .blob(Data()))
    }
}
