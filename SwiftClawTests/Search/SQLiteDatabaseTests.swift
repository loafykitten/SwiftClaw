import Foundation
import Testing
@testable import SwiftClaw

struct SQLiteDatabaseTests {
    @Test func executeAndQueryRoundTripValues() async throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try await database.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, weight REAL, blob BLOB);")
        try await database.execute(
            "INSERT INTO items (id, name, weight, blob) VALUES (?, ?, ?, ?);",
            params: [.integer(1), .text("hello"), .real(2.5), .blob(Data([0x01, 0x02, 0x03]))]
        )

        let rows = try await database.query("SELECT id, name, weight, blob FROM items WHERE id = ?;", params: [.integer(1)])
        #expect(rows.count == 1)
        #expect(rows[0] == [.integer(1), .text("hello"), .real(2.5), .blob(Data([0x01, 0x02, 0x03]))])
    }

    @Test func preparedStatementsAreReusedAcrossCalls() async throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try await database.execute("CREATE TABLE counters (n INTEGER);")
        for value in 0..<5 {
            try await database.execute("INSERT INTO counters (n) VALUES (?);", params: [.integer(Int64(value))])
        }
        let rows = try await database.query("SELECT n FROM counters ORDER BY n;")
        #expect(rows.map { $0[0] } == (0..<5).map { .integer(Int64($0)) })
    }

    @Test func transactionCommitsOnSuccessAndRollsBackOnThrow() async throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try await database.execute("CREATE TABLE items (n INTEGER);")

        let committed = try await database.transaction { database in
            try database.execute("INSERT INTO items (n) VALUES (1);")
            return try database.query("SELECT COUNT(*) FROM items;")
        }
        #expect(committed == [[.integer(1)]])

        await #expect(throws: SQLiteDatabase.DatabaseError.self) {
            try await database.transaction { database in
                try database.execute("INSERT INTO items (n) VALUES (2);")
                try database.execute("NOT VALID SQL;")
            }
        }

        let rows = try await database.query("SELECT n FROM items;")
        #expect(rows == [[.integer(1)]])
        // A follow-up transaction proves the failed one didn't leave BEGIN open.
        try await database.transaction { database in
            try database.execute("INSERT INTO items (n) VALUES (3);")
        }
    }

    @Test func userVersionDefaultsToZeroAndPersistsAfterBeingSet() async throws {
        let database = try SQLiteDatabase(path: ":memory:")
        #expect(try await database.currentUserVersion() == 0)
        try await database.setUserVersion(3)
        #expect(try await database.currentUserVersion() == 3)
    }

    @Test func fts5ProbeSucceedsOnAWritableDatabase() async throws {
        let database = try SQLiteDatabase(path: ":memory:")
        #expect(await database.probeFTS5())
    }

    @Test func invalidSQLThrowsRatherThanCrashing() async throws {
        let database = try SQLiteDatabase(path: ":memory:")
        await #expect(throws: SQLiteDatabase.DatabaseError.self) {
            try await database.execute("INSERT INTO nonexistent_table (n) VALUES (1);")
        }
    }
}
