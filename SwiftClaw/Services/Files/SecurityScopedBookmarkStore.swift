import Foundation

/// Persists security-scoped bookmarks so the sandboxed app can keep access
/// to a user-picked file or folder (e.g. an external Notes vault chosen via
/// `NSOpenPanel`) across relaunches. `@MainActor` because bookmarks are
/// created/resolved in response to UI actions (an open panel, app launch)
/// and there is exactly one of each per key — no need for actor-isolated
/// file work here.
@MainActor
final class SecurityScopedBookmarkStore {
    enum StoreError: LocalizedError {
        case bookmarkCreationFailed(underlying: Error)
        case bookmarkNotFound(key: String)
        case bookmarkResolutionFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .bookmarkCreationFailed(let underlying):
                "Couldn't create a security-scoped bookmark: \(underlying.localizedDescription)"
            case .bookmarkNotFound(let key):
                "No bookmark saved for \"\(key)\"."
            case .bookmarkResolutionFailed(let underlying):
                "Couldn't resolve the saved bookmark: \(underlying.localizedDescription)"
            }
        }
    }

    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    private let userDefaults: UserDefaults

    /// `userDefaults` is injectable so tests can point at an isolated suite
    /// instead of `.standard` — see `SettingsStorage` conventions.
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Creates a security-scoped bookmark for `url` and stores it under
    /// `key`, overwriting any bookmark already saved there.
    @discardableResult
    func save(url: URL, forKey key: String) throws -> Data {
        do {
            let data = try url.bookmarkData(
                options: Self.creationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            userDefaults.set(data, forKey: key)
            return data
        } catch {
            throw StoreError.bookmarkCreationFailed(underlying: error)
        }
    }

    /// Resolves the bookmark saved under `key` into a `ScopedURL` access
    /// token. Transparently re-saves the bookmark if the system reports it
    /// stale (e.g. the volume was renamed) — the caller still gets a valid
    /// URL for the current call, and future resolves pick up the refreshed
    /// data.
    func resolve(forKey key: String) throws -> ScopedURL {
        guard let data = userDefaults.data(forKey: key) else {
            throw StoreError.bookmarkNotFound(key: key)
        }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: Self.resolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw StoreError.bookmarkResolutionFailed(underlying: error)
        }

        if isStale {
            _ = try? save(url: url, forKey: key)
        }

        return ScopedURL(url: url)
    }

    /// Removes the bookmark saved under `key`, if any.
    func remove(forKey key: String) {
        userDefaults.removeObject(forKey: key)
    }
}

/// A lifetime token for security-scoped access to a resolved bookmark URL.
/// `start`s access on init and balances it with exactly one `stop` on
/// deinit — but only when access actually started, so this stays correct
/// for plain macOS URLs that never needed a security scope in the first
/// place (`startAccessingSecurityScopedResource` is a documented safe no-op
/// for those, returning `true` without requiring a matching stop, but we
/// still balance it defensively since the return value is our only signal).
///
/// Hold this token for as long as the URL needs to remain accessible; do not
/// discard it before finishing file work.
final class ScopedURL: @unchecked Sendable {
    let url: URL
    private let didStartAccess: Bool

    init(url: URL) {
        self.url = url
        self.didStartAccess = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
