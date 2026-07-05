import Foundation
import SwiftMail

/// The subset of `IMAPServer` lifecycle that `IMAPSession` manages. Extracted
/// so the session's reuse/teardown/idle logic is testable with a mock
/// connection (`IMAPSessionTests`) without a live server.
protocol IMAPSessionConnection: Actor {
    var isConnected: Bool { get }
    func connect() async throws
    func login(username: String, password: String) async throws
    /// Cheap round-trip that fails when the connection has gone stale
    /// (server dropped it, network changed). IMAP NOOP on the real client.
    func probeLiveness() async throws
    func disconnect() async throws
}

extension IMAPServer: IMAPSessionConnection {
    func probeLiveness() async throws {
        _ = try await noop()
    }
}

/// One persistent, authenticated IMAP connection shared by successive
/// operations, replacing the previous connect → TLS → login → disconnect
/// cycle per call (a sync pass over N folders used to pay ~2N full
/// handshakes per account).
///
/// Semantics:
/// - Operations are serialized FIFO: `IMAPServer` multiplexes commands over
///   one connection, so two interleaved operations could SELECT different
///   mailboxes under each other. `perform` blocks therefore run one at a
///   time per session; the pool hands out separate sessions per channel so
///   quick interactive mutations don't queue behind a long sync fetch.
/// - Connect + login happen lazily on first use. A reused connection is
///   probed with NOOP when it has sat unused past `probeThreshold` (a
///   reuse within the threshold skips the probe — the connection was live
///   milliseconds ago).
/// - Any error inside `perform` tears the connection down; there is NO
///   automatic retry of the body, because a mid-operation failure could
///   have already applied a non-idempotent command (MOVE, APPEND, EXPUNGE).
///   The next `perform` reconnects fresh.
/// - The connection closes itself after `idleTimeout` without use, so quiet
///   periods don't hold sockets open against server per-user limits.
actor IMAPSession<Connection: IMAPSessionConnection> {
    private let host: String
    private let port: Int
    private let idleTimeout: Duration
    private let probeThreshold: Duration
    private let makeConnection: @Sendable (String, Int) -> Connection

    private var connection: Connection?
    private var lastUsedAt: ContinuousClock.Instant?

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var idleCloseGeneration = 0

    init(
        host: String,
        port: Int,
        idleTimeout: Duration = .seconds(60),
        probeThreshold: Duration = .seconds(5),
        makeConnection: @escaping @Sendable (String, Int) -> Connection
    ) {
        self.host = host
        self.port = port
        self.idleTimeout = idleTimeout
        self.probeThreshold = probeThreshold
        self.makeConnection = makeConnection
    }

    /// Runs `body` against a live, authenticated connection, reusing the
    /// cached one when possible. Serialized against other `perform` calls
    /// on this session.
    func perform<T: Sendable>(
        username: String,
        password: String,
        _ body: @Sendable (Connection) async throws -> T
    ) async throws -> T {
        await acquire()
        defer { releaseAndScheduleIdleClose() }

        let live = try await liveConnection(username: username, password: password)
        do {
            let result = try await body(live)
            lastUsedAt = .now
            return result
        } catch {
            // Conservative teardown: the connection state after a failed
            // command is unknown (half-applied SELECT, dropped socket), so
            // drop it rather than risk the next operation running against it.
            await invalidate()
            throw error
        }
    }

    // MARK: - Connection lifecycle

    private func liveConnection(username: String, password: String) async throws -> Connection {
        if let existing = connection {
            if await existing.isConnected {
                let recentlyUsed = lastUsedAt.map { ContinuousClock.now - $0 < probeThreshold } ?? false
                if recentlyUsed {
                    return existing
                }
                if (try? await existing.probeLiveness()) != nil {
                    return existing
                }
            }
            await invalidate()
        }

        let fresh = makeConnection(host, port)
        try await fresh.connect()
        try await fresh.login(username: username, password: password)
        connection = fresh
        lastUsedAt = .now
        return fresh
    }

    private func invalidate() async {
        guard let existing = connection else { return }
        connection = nil
        try? await existing.disconnect()
    }

    // MARK: - FIFO serialization + idle close

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        // Resumed by `releaseAndScheduleIdleClose`, which keeps `isBusy`
        // true and hands the session directly to this waiter.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseAndScheduleIdleClose() {
        idleCloseGeneration += 1
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
            return
        }
        isBusy = false
        let generation = idleCloseGeneration
        Task { [idleTimeout] in
            try? await Task.sleep(for: idleTimeout)
            await self.closeIfIdle(generation: generation)
        }
    }

    private func closeIfIdle(generation: Int) async {
        // A newer release (or an in-flight operation) supersedes this timer.
        guard !isBusy, generation == idleCloseGeneration else { return }
        await invalidate()
    }
}

/// Hands out the shared per-account `IMAPSession`s. Keyed by account id +
/// host/port/username so a settings change naturally rotates to a fresh
/// session (the superseded one closes itself via the idle timeout).
///
/// Two channels per account:
/// - `.sync` — long-running reads (mailbox fetches, UID-set scans, LIST),
///   used by `MailSyncWorker`'s pass.
/// - `.interactive` — quick user-initiated mutations (flags, move, expunge,
///   Sent APPEND), so they don't queue behind a multi-minute first sync on
///   the `.sync` channel.
///
/// Two connections per account stays well under typical server limits
/// (Gmail allows 15 simultaneous IMAP connections).
actor IMAPSessionPool {
    static let shared = IMAPSessionPool()

    enum Channel: Hashable {
        case sync
        case interactive
    }

    private struct Key: Hashable {
        let accountID: UUID
        let host: String
        let port: Int
        let username: String
        let channel: Channel
    }

    private var sessions: [Key: IMAPSession<IMAPServer>] = [:]

    func session(for account: StoredEmailAccount, channel: Channel) -> IMAPSession<IMAPServer> {
        let key = Key(
            accountID: account.id,
            host: account.imapHost,
            port: account.imapPort,
            username: account.imapUsername,
            channel: channel
        )
        if let existing = sessions[key] {
            return existing
        }
        // Drop superseded entries for the same account+channel (host or
        // username changed in Settings); their connections idle-close on
        // their own.
        sessions = sessions.filter { $0.key.accountID != key.accountID || $0.key.channel != key.channel }
        let fresh = IMAPSession<IMAPServer>(host: key.host, port: key.port) { host, port in
            IMAPServer(host: host, port: port)
        }
        sessions[key] = fresh
        return fresh
    }
}
