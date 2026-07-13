import Foundation
import Testing
@testable import SwiftClaw

@MainActor
struct SecurityScopedBookmarkStoreTests {
    private static let key = "test.bookmark.key"

    private func makeTempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data("hello".utf8).write(to: url)
        return url
    }

    @Test func saveAndResolveRoundTripsTheSameLocation() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let fileURL = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = SecurityScopedBookmarkStore(userDefaults: fixture.defaults)
        try store.save(url: fileURL, forKey: Self.key)

        let scoped = try store.resolve(forKey: Self.key)

        #expect(scoped.url.standardizedFileURL.path == fileURL.standardizedFileURL.path)
        // Access started by the token should make the file readable.
        let contents = try Data(contentsOf: scoped.url)
        #expect(String(decoding: contents, as: UTF8.self) == "hello")
    }

    @Test func resolveWithoutASavedBookmarkThrowsNotFound() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let store = SecurityScopedBookmarkStore(userDefaults: fixture.defaults)

        #expect(throws: SecurityScopedBookmarkStore.StoreError.self) {
            try store.resolve(forKey: "missing.key")
        }
    }

    @Test func saveOverwritesAPreviouslyStoredBookmarkForTheSameKey() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let firstFile = try makeTempFile()
        let secondFile = try makeTempFile()
        defer {
            try? FileManager.default.removeItem(at: firstFile)
            try? FileManager.default.removeItem(at: secondFile)
        }

        let store = SecurityScopedBookmarkStore(userDefaults: fixture.defaults)
        try store.save(url: firstFile, forKey: Self.key)
        try store.save(url: secondFile, forKey: Self.key)

        let scoped = try store.resolve(forKey: Self.key)
        #expect(scoped.url.standardizedFileURL.path == secondFile.standardizedFileURL.path)
    }

    @Test func removeClearsTheStoredBookmark() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let fileURL = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = SecurityScopedBookmarkStore(userDefaults: fixture.defaults)
        try store.save(url: fileURL, forKey: Self.key)
        store.remove(forKey: Self.key)

        #expect(throws: SecurityScopedBookmarkStore.StoreError.self) {
            try store.resolve(forKey: Self.key)
        }
    }

    @Test func independentStoresBackedByDifferentDefaultsDoNotShareBookmarks() throws {
        let fixtureA = try UserDefaultsFixture()
        defer { fixtureA.cleanup() }
        let fixtureB = try UserDefaultsFixture()
        defer { fixtureB.cleanup() }
        let fileURL = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let storeA = SecurityScopedBookmarkStore(userDefaults: fixtureA.defaults)
        let storeB = SecurityScopedBookmarkStore(userDefaults: fixtureB.defaults)
        try storeA.save(url: fileURL, forKey: Self.key)

        #expect(throws: SecurityScopedBookmarkStore.StoreError.self) {
            try storeB.resolve(forKey: Self.key)
        }
    }

    @Test func scopedURLDeinitReleasesAccessWithoutCrashing() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        let fileURL = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let store = SecurityScopedBookmarkStore(userDefaults: fixture.defaults)
        try store.save(url: fileURL, forKey: Self.key)

        do {
            let scoped = try store.resolve(forKey: Self.key)
            _ = scoped.url
        }
        // The token above has gone out of scope and deinited; resolving again
        // should still succeed, proving the store's saved bookmark survives
        // (and that balancing stop-access didn't throw/crash).
        let scopedAgain = try store.resolve(forKey: Self.key)
        #expect(scopedAgain.url.standardizedFileURL.path == fileURL.standardizedFileURL.path)
    }
}
