// Checks that the toolchain builds and links what the core depends on,
// on Linux and on macOS: the system SQLite and swift-markdown.

import CSQLite
import Markdown
import Testing

@Suite struct ToolchainTests {
    @Test func sqliteSupportsStrictTablesAndJSON() throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        // STRICT tables need 3.37, the JSON functions 3.38.
        #expect(sqlite3_libversion_number() >= 3_038_000)
        let sql = """
            CREATE TABLE t (body TEXT NOT NULL CHECK (json_valid(body))) STRICT;
            INSERT INTO t VALUES ('{"a": 1}');
            """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "INSERT INTO t VALUES ('not json')", nil, nil, nil) == SQLITE_CONSTRAINT)
    }

    @Test func markdownParsesATable() {
        let document = Document(parsing: "| a | b |\n|---|---|\n| 1 | 2 |\n")
        let table = document.child(at: 0) as? Markdown.Table
        #expect(table != nil)
        #expect(table?.maxColumnCount == 2)
    }
}
