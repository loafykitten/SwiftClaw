import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        /// `createExclusive` lost the race: something else (another process,
        /// or a concurrent creator) already has a file at that exact path.
        case alreadyExists
        case createFailed(errno: Int32)
        /// A byte-level write to the (still-temporary, unpublished) file
        /// failed — the caller must not publish a partial temp file.
        case writeFailed(errno: Int32)
        /// The final atomic publish (hard-link from the complete temp file
        /// to the destination path) failed for a reason other than the
        /// destination already existing — e.g. the destination volume
        /// doesn't support hard links. The temp file is never left behind
        /// and the destination is never partially written.
        case publishFailed(errno: Int32)

        var errorDescription: String? {
            switch self {
            case .temporaryWriteFailed(let underlying):
                "Couldn't write the temporary file: \(underlying.localizedDescription)"
            case .replaceFailed(let underlying):
                "Couldn't replace the destination file: \(underlying.localizedDescription)"
            case .alreadyExists:
                "A file already exists at that path."
            case .createFailed(let errno):
                "Couldn't create the file: \(String(cString: strerror(errno)))"
            case .writeFailed(let errno):
                "Couldn't write the file: \(String(cString: strerror(errno)))"
            case .publishFailed(let errno):
                "Couldn't publish the file: \(String(cString: strerror(errno)))"
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

    /// Atomically creates a new file at `url` **iff nothing exists there
    /// yet** — throws `.alreadyExists` rather than overwriting or falling
    /// back to a sibling path. Write-before-publish: the full content is
    /// written to a uniquely-named temp file *in the same directory* first
    /// (with a robust byte-loop write handling partial POSIX writes/`EINTR`,
    /// then `fsync`ed and closed), and only that already-complete file is
    /// published to `url` — via an atomic hard link (`link(2)`, which fails
    /// with `EEXIST` rather than silently overwriting when the destination
    /// already exists), followed by unlinking the temp name and `fsync`ing
    /// the directory. Unlike opening the final path directly, this means no
    /// reader (or a crash) can ever observe an empty or partially-written
    /// file at `url`: the path either doesn't exist yet, or it already has
    /// its complete final content. On any failure the temp file is always
    /// cleaned up and `url` is left exactly as it was (absent, or whatever
    /// pre-existing file was already there) — never overwritten, never
    /// partially written. A destination volume that doesn't support hard
    /// links (rare on Apple platforms — some exotic/network filesystems)
    /// surfaces as `.publishFailed` with a clear underlying message rather
    /// than silently falling back to an overwrite.
    static func createExclusive(
        _ data: Data,
        at url: URL,
        createDirectories: Bool = true,
        fileManager: FileManager = .default
    ) throws {
        let directory = url.deletingLastPathComponent()
        if createDirectories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).createtmp")
        let tempDescriptor = tempURL.withUnsafeFileSystemRepresentation { cPath -> Int32 in
            guard let cPath else { return -1 }
            return open(cPath, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        }
        guard tempDescriptor >= 0 else {
            throw WriteError.createFailed(errno: errno)
        }

        do {
            try writeAllBytes(data, to: tempDescriptor)
        } catch {
            close(tempDescriptor)
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
        guard fsync(tempDescriptor) == 0 else {
            let syncErrno = errno
            close(tempDescriptor)
            try? fileManager.removeItem(at: tempURL)
            throw WriteError.writeFailed(errno: syncErrno)
        }
        guard close(tempDescriptor) == 0 else {
            let closeErrno = errno
            try? fileManager.removeItem(at: tempURL)
            throw WriteError.writeFailed(errno: closeErrno)
        }

        let linkResult = url.withUnsafeFileSystemRepresentation { finalPath -> Int32 in
            tempURL.withUnsafeFileSystemRepresentation { tempPath -> Int32 in
                guard let finalPath, let tempPath else { return -1 }
                return link(tempPath, finalPath)
            }
        }
        guard linkResult == 0 else {
            let linkErrno = errno
            try? fileManager.removeItem(at: tempURL)
            if linkErrno == EEXIST {
                throw WriteError.alreadyExists
            }
            throw WriteError.publishFailed(errno: linkErrno)
        }

        try? fileManager.removeItem(at: tempURL)
        fsyncDirectory(directory)
    }

    /// Writes every byte of `data` to `descriptor`, looping on a short write
    /// (POSIX `write(2)` may write fewer bytes than requested even without
    /// error) and retrying on `EINTR` rather than treating either as failure
    /// or silently truncating the file.
    private static func writeAllBytes(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            var remaining = rawBuffer.count
            var currentPointer = rawBuffer.baseAddress
            while remaining > 0 {
                guard let pointer = currentPointer else { break }
                // Qualified with the platform module: an unqualified `write`
                // here would resolve to `AtomicFileWriter.write(_:to:...)`
                // (this type's own static method) instead of the POSIX
                // syscall, since unqualified lookup inside a type prefers
                // its own members over an imported global function.
                #if canImport(Darwin)
                let bytesWritten = Darwin.write(descriptor, pointer, remaining)
                #elseif canImport(Glibc)
                let bytesWritten = Glibc.write(descriptor, pointer, remaining)
                #endif
                if bytesWritten < 0 {
                    if errno == EINTR { continue }
                    throw WriteError.writeFailed(errno: errno)
                }
                if bytesWritten == 0 { break }
                remaining -= bytesWritten
                currentPointer = pointer.advanced(by: bytesWritten)
            }
            guard remaining == 0 else {
                throw WriteError.writeFailed(errno: EIO)
            }
        }
    }

    /// Best-effort directory `fsync` after a publish — ensures the new
    /// directory entry (the hard link) itself is durable, not just the file
    /// contents. Silently does nothing if the directory can't be opened;
    /// this is a durability best-effort, not a correctness requirement for
    /// `createExclusive`'s no-partial-content guarantee.
    private static func fsyncDirectory(_ directory: URL) {
        let directoryDescriptor = directory.withUnsafeFileSystemRepresentation { cPath -> Int32 in
            guard let cPath else { return -1 }
            return open(cPath, O_RDONLY)
        }
        guard directoryDescriptor >= 0 else { return }
        fsync(directoryDescriptor)
        close(directoryDescriptor)
    }
}
