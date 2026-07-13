import Foundation
import Testing
@testable import SwiftClaw

struct AtomicFileWriterTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writesANewFileWhenNoneExists() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("note.md")

        try AtomicFileWriter.write(Data("hello".utf8), to: fileURL)

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try Data(contentsOf: fileURL) == Data("hello".utf8))
    }

    @Test func replacesAnExistingFileAtomically() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("note.md")
        try Data("original".utf8).write(to: fileURL)

        try AtomicFileWriter.write(Data("updated".utf8), to: fileURL)

        #expect(try Data(contentsOf: fileURL) == Data("updated".utf8))
    }

    @Test func createsParentDirectoriesWhenRequested() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory
            .appendingPathComponent("nested/deeper")
            .appendingPathComponent("note.md")

        try AtomicFileWriter.write(Data("hello".utf8), to: fileURL, createDirectories: true)

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func doesNotCreateParentDirectoriesWhenDisabled() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory
            .appendingPathComponent("nested-missing")
            .appendingPathComponent("note.md")

        #expect(throws: AtomicFileWriter.WriteError.self) {
            try AtomicFileWriter.write(Data("hello".utf8), to: fileURL, createDirectories: false)
        }
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func leavesNoTemporaryArtifactsBehindOnSuccess() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("note.md")

        try AtomicFileWriter.write(Data("hello".utf8), to: fileURL)

        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries == ["note.md"])
    }

    @Test func preservesOriginalContentWhenTheTemporaryWriteFails() throws {
        // Make the directory read-only so the temp-file write fails before
        // any swap is attempted; the pre-existing file's content must
        // survive untouched.
        let directory = try makeTempDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let destination = directory.appendingPathComponent("note.md")
        try Data("original".utf8).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        #expect(throws: AtomicFileWriter.WriteError.self) {
            try AtomicFileWriter.write(Data("updated".utf8), to: destination)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(try Data(contentsOf: destination) == Data("original".utf8))

        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries == ["note.md"])
    }
}
