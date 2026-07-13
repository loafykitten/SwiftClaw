import Foundation

/// Writes file contents so a crash or error never leaves a half-written
/// file in place: content lands in a temp file *in the destination's own
/// directory* first, then `FileManager.replaceItemAt`/`moveItem` swaps it
/// into place in one filesystem operation. On any failure before that swap,
/// the original file (or its absence) is left untouched.
///
/// `nonisolated` and stateless by design — every call is self-contained, so
/// this is safe to call from any actor, including a later actor-isolated
/// vault type that serializes its own file operations.
nonisolated enum AtomicFileWriter {
    enum WriteError: LocalizedError {
        case temporaryWriteFailed(underlying: Error)
        case replaceFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .temporaryWriteFailed(let underlying):
                "Couldn't write the temporary file: \(underlying.localizedDescription)"
            case .replaceFailed(let underlying):
                "Couldn't replace the destination file: \(underlying.localizedDescription)"
            }
        }
    }

    /// Atomically writes `data` to `url`. When `createDirectories` is true
    /// (the default), creates `url`'s parent directory tree first — the temp
    /// file must land next to the destination so the final swap stays on one
    /// volume.
    static func write(
        _ data: Data,
        to url: URL,
        createDirectories: Bool = true,
        fileManager: FileManager = .default
    ) throws {
        let directory = url.deletingLastPathComponent()
        if createDirectories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL)
        } catch {
            throw WriteError.temporaryWriteFailed(underlying: error)
        }

        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw WriteError.replaceFailed(underlying: error)
        }
    }
}
