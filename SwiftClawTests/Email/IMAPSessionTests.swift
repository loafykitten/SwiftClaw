import Foundation
import Testing
@testable import SwiftClaw

// MARK: - Mock connection

private struct MockConnectionError: Error {}

private actor MockIMAPConnection: IMAPSessionConnection {
    private(set) var isConnected = false
    private(set) var connectCount = 0
    private(set) var loginCount = 0
    private(set) var probeCount = 0
    private(set) var disconnectCount = 0
    private var failNextProbe = false

    func connect() async throws {
        connectCount += 1
        isConnected = true
    }

    func login(username: String, password: String) async throws {
        loginCount += 1
    }

    func probeLiveness() async throws {
        probeCount += 1
        if failNextProbe {
            failNextProbe = false
            isConnected = false
            throw MockConnectionError()
        }
    }

    func disconnect() async throws {
        disconnectCount += 1
        isConnected = false
    }

    func setFailNextProbe() {
        failNextProbe = true
    }
}

/// Thread-safe record of every connection the session's factory created, so
/// tests can assert reuse vs. reconnect without racing the factory closure.
private nonisolated final class MockConnectionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [MockIMAPConnection] = []

    var created: [MockIMAPConnection] {
        lock.withLock { connections }
    }

    func make() -> MockIMAPConnection {
        let connection = MockIMAPConnection()
        lock.withLock { connections.append(connection) }
        return connection
    }
}

private func makeSession(
    factory: MockConnectionFactory,
    idleTimeout: Duration = .seconds(60),
    probeThreshold: Duration = .seconds(60)
) -> IMAPSession<MockIMAPConnection> {
    IMAPSession(
        host: "imap.example.test",
        port: 993,
        idleTimeout: idleTimeout,
        probeThreshold: probeThreshold
    ) { _, _ in factory.make() }
}

// MARK: - Tests

@Suite("IMAPSession")
struct IMAPSessionTests {
    @Test("Sequential operations reuse one connection and one login")
    func reusesConnection() async throws {
        let factory = MockConnectionFactory()
        let session = makeSession(factory: factory)

        for _ in 0..<3 {
            try await session.perform(username: "u", password: "p") { _ in }
        }

        let connection = try #require(factory.created.first)
        #expect(factory.created.count == 1)
        #expect(await connection.connectCount == 1)
        #expect(await connection.loginCount == 1)
        // Reuse within `probeThreshold` skips the liveness probe entirely.
        #expect(await connection.probeCount == 0)
    }

    @Test("Reuse past the probe threshold sends a liveness probe first")
    func probesStaleConnection() async throws {
        let factory = MockConnectionFactory()
        let session = makeSession(factory: factory, probeThreshold: .zero)

        try await session.perform(username: "u", password: "p") { _ in }
        try await session.perform(username: "u", password: "p") { _ in }

        let connection = try #require(factory.created.first)
        #expect(factory.created.count == 1)
        #expect(await connection.probeCount == 1)
    }

    @Test("A dead connection (failed probe) is replaced before the operation runs")
    func reconnectsAfterFailedProbe() async throws {
        let factory = MockConnectionFactory()
        let session = makeSession(factory: factory, probeThreshold: .zero)

        try await session.perform(username: "u", password: "p") { _ in }
        await factory.created[0].setFailNextProbe()
        let bodyRan = try await session.perform(username: "u", password: "p") { _ in true }

        #expect(bodyRan)
        #expect(factory.created.count == 2)
        #expect(await factory.created[0].disconnectCount == 1)
        #expect(await factory.created[1].connectCount == 1)
        #expect(await factory.created[1].loginCount == 1)
    }

    @Test("A failing operation tears the connection down; the next one reconnects")
    func invalidatesOnBodyError() async throws {
        let factory = MockConnectionFactory()
        let session = makeSession(factory: factory)

        try await session.perform(username: "u", password: "p") { _ in }
        await #expect(throws: MockConnectionError.self) {
            try await session.perform(username: "u", password: "p") { _ in
                throw MockConnectionError()
            }
        }
        try await session.perform(username: "u", password: "p") { _ in }

        #expect(factory.created.count == 2)
        #expect(await factory.created[0].disconnectCount == 1)
    }

    @Test("Concurrent operations are serialized, never interleaved")
    func serializesOperations() async throws {
        let factory = MockConnectionFactory()
        let session = makeSession(factory: factory)

        actor OverlapProbe {
            private var active = 0
            private(set) var sawOverlap = false
            private(set) var completed = 0

            func enter() {
                active += 1
                if active > 1 { sawOverlap = true }
            }

            func exit() {
                active -= 1
                completed += 1
            }
        }
        let probe = OverlapProbe()

        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await session.perform(username: "u", password: "p") { _ in
                        await probe.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        await probe.exit()
                    }
                }
            }
        }

        #expect(await probe.completed == 4)
        #expect(await probe.sawOverlap == false)
    }

    @Test("The connection closes itself after the idle timeout")
    func closesWhenIdle() async throws {
        let factory = MockConnectionFactory()
        let session = makeSession(factory: factory, idleTimeout: .milliseconds(30))

        try await session.perform(username: "u", password: "p") { _ in }

        let connection = try #require(factory.created.first)
        // Poll rather than a single fixed sleep — the idle-close task's
        // wakeup isn't deadline-exact under load.
        var closed = false
        for _ in 0..<100 {
            if await connection.disconnectCount == 1 {
                closed = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(closed)

        // The session recovers transparently: the next operation reconnects.
        try await session.perform(username: "u", password: "p") { _ in }
        #expect(factory.created.count == 2)
    }
}
