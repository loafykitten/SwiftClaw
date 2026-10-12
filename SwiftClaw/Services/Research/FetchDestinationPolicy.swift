import Darwin
import Foundation
import Synchronization

/// Decides whether a research fetch may contact a URL. Search results are
/// attacker-influenced, and fetched text flows into prompts sent to the
/// inference provider, so a page (or a redirect) must not be able to point the
/// fetcher at loopback, private, or link-local services on the user's network.
nonisolated enum FetchDestinationPolicy {
    /// Resolves a host name to raw IPv4 (4-byte) or IPv6 (16-byte) addresses.
    typealias HostResolver = @Sendable (String) async -> [[UInt8]]

    /// Whether `url` is an http(s) URL whose host resolves only to public
    /// addresses. Unresolvable hosts are rejected, failing closed.
    static func allows(_ url: URL, resolveHost: HostResolver) async -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = url.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty else {
            return false
        }

        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }

        let addresses: [[UInt8]]
        if let literal = numericAddress(host) {
            addresses = [literal]
        } else {
            addresses = await resolveHost(host)
        }
        return !addresses.isEmpty && addresses.allSatisfy(isPublicAddress)
    }

    /// One transaction URLSession actually performed for a fetch, as its task
    /// metrics report it. ``allows(_:resolveHost:)`` checks a host before the
    /// request; this records where the connection really went, closing the
    /// gap where DNS answers differently (rebinding) by the time URLSession
    /// resolves the host itself.
    struct Connection: Sendable, Equatable {
        enum FetchType: Sendable, Equatable {
            case network
            case serverPush
            case localCache
            case unknown
        }

        var remoteAddress: String?
        var isProxyConnection: Bool
        var fetchType: FetchType

        init(remoteAddress: String?, isProxyConnection: Bool = false, fetchType: FetchType = .network) {
            self.remoteAddress = remoteAddress
            self.isProxyConnection = isProxyConnection
            self.fetchType = fetchType
        }

        init(_ transaction: URLSessionTaskTransactionMetrics) {
            let fetchType: FetchType = switch transaction.resourceFetchType {
            case .networkLoad: .network
            case .serverPush: .serverPush
            case .localCache: .localCache
            default: .unknown
            }
            self.init(
                remoteAddress: transaction.remoteAddress,
                isProxyConnection: transaction.isProxyConnection,
                fetchType: fetchType
            )
        }
    }

    /// Whether every transaction of a finished fetch (each redirect hop is
    /// one) connected to a public address. Fails closed: no transactions, an
    /// unknown or cache-served load (the fetch session has no cache, so the
    /// body's origin can't be vouched for), or a missing or unparseable
    /// address all reject.
    ///
    /// A system-proxy hop is allowed without an address check: its remote
    /// address is the proxy's (often on the LAN by design), and the proxy —
    /// configured by the user or their admin — resolves the target itself.
    /// The pre-flight ``allows(_:resolveHost:)`` check still applies to it.
    static func allowsConnections(_ connections: [Connection]) -> Bool {
        !connections.isEmpty && connections.allSatisfy { connection in
            switch connection.fetchType {
            case .network, .serverPush:
                break
            case .localCache, .unknown:
                return false
            }
            if connection.isProxyConnection {
                return true
            }
            guard let remoteAddress = connection.remoteAddress,
                  let address = remoteAddressBytes(remoteAddress) else {
                return false
            }
            return isPublicAddress(address)
        }
    }

    /// Parses a metrics `remoteAddress`: IPv4, IPv6 (optionally bracketed),
    /// IPv4-mapped IPv6, or scoped link-local such as `fe80::1%en0` (the zone
    /// is dropped; the address classifies as link-local either way).
    static func remoteAddressBytes(_ remoteAddress: String) -> [UInt8]? {
        var host = Substring(remoteAddress.trimmingCharacters(in: .whitespaces))
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = host.dropFirst().dropLast()
        }
        if let zone = host.firstIndex(of: "%") {
            host = host[..<zone]
        }
        return numericAddress(String(host))
    }

    /// Parses a dotted-quad IPv4 or textual IPv6 literal.
    static func numericAddress(_ host: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }

        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }

        return nil
    }

    /// Whether an address is globally routable — not loopback, private,
    /// link-local, shared (CGNAT), multicast, or otherwise reserved.
    static func isPublicAddress(_ bytes: [UInt8]) -> Bool {
        switch bytes.count {
        case 4:
            return isPublicIPv4(bytes)
        case 16:
            return isPublicIPv6(bytes)
        default:
            return false
        }
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        let (a, b, c) = (bytes[0], bytes[1], bytes[2])
        switch a {
        case 0, 10, 127: return false
        case 100 where (64..<128).contains(b): return false
        case 169 where b == 254: return false
        case 172 where (16..<32).contains(b): return false
        case 192 where b == 168: return false
        case 192 where b == 0 && c == 0: return false
        case 198 where b == 18 || b == 19: return false
        case 224...: return false
        default: return true
        }
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        let embeddedIPv4 = Array(bytes[12..<16])

        // ::/128, ::1, and the deprecated IPv4-compatible ::a.b.c.d form.
        if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            return isPublicIPv4(embeddedIPv4)
        }

        // IPv4-mapped ::ffff:a.b.c.d.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return isPublicIPv4(embeddedIPv4)
        }

        // NAT64 64:ff9b::/96 translates to the embedded IPv4 address.
        if bytes[0..<4].elementsEqual([0x00, 0x64, 0xff, 0x9b]), bytes[4..<12].allSatisfy({ $0 == 0 }) {
            return isPublicIPv4(embeddedIPv4)
        }

        // 6to4 2002::/16 embeds the IPv4 address in bytes 2–5.
        if bytes[0] == 0x20, bytes[1] == 0x02 {
            return isPublicIPv4(Array(bytes[2..<6]))
        }

        if bytes[0] & 0xfe == 0xfc { return false } // fc00::/7 unique local
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false } // fe80::/10 link-local
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0xc0 { return false } // fec0::/10 site-local
        if bytes[0] == 0xff { return false } // ff00::/8 multicast
        return true
    }

    /// Resolves through the system resolver on a background queue, since
    /// `getaddrinfo` blocks.
    static let systemResolver: HostResolver = { host in
        await resolve(host, blockingLookup: resolveSynchronously)
    }

    /// Runs a blocking lookup off the cooperative pool, returning no
    /// addresses (failing closed) as soon as the calling task is cancelled.
    /// `getaddrinfo` itself can't be interrupted, so a stalled lookup keeps
    /// its background thread until DNS gives up; its late result is dropped.
    static func resolve(
        _ host: String,
        blockingLookup: @escaping @Sendable (String) -> [[UInt8]]
    ) async -> [[UInt8]] {
        guard !Task.isCancelled else { return [] }
        let waiter = ResolutionWaiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard waiter.install(continuation) else { return }
                DispatchQueue.global(qos: .utility).async {
                    waiter.finish(with: blockingLookup(host))
                }
            }
        } onCancel: {
            waiter.finish(with: [])
        }
    }

    private static func resolveSynchronously(_ host: String) -> [[UInt8]] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0 else { return [] }
        defer { freeaddrinfo(head) }

        var addresses = [[UInt8]]()
        var cursor = head
        while let info = cursor?.pointee {
            if let address = info.ai_addr {
                switch info.ai_family {
                case AF_INET:
                    var v4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee.sin_addr
                    }
                    addresses.append(withUnsafeBytes(of: &v4) { Array($0) })
                case AF_INET6:
                    var v6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        $0.pointee.sin6_addr
                    }
                    addresses.append(withUnsafeBytes(of: &v6) { Array($0) })
                default:
                    break
                }
            }
            cursor = info.ai_next
        }
        return addresses
    }
}

/// Resumes one resolution continuation exactly once, whichever of the lookup
/// or cancellation finishes first. Cancellation can arrive before the
/// continuation is installed, so a result that lands early is held for it.
private nonisolated final class ResolutionWaiter: Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<[[UInt8]], Never>)
        case finished([[UInt8]])
        case resumed
    }

    private let state = Mutex(State.pending)

    /// `false` when cancellation already resumed `continuation`, so the
    /// caller can skip starting a lookup nobody will read.
    func install(_ continuation: CheckedContinuation<[[UInt8]], Never>) -> Bool {
        let early: [[UInt8]]? = state.withLock { state in
            guard case .finished(let addresses) = state else {
                state = .waiting(continuation)
                return nil
            }
            state = .resumed
            return addresses
        }
        guard let early else { return true }
        continuation.resume(returning: early)
        return false
    }

    func finish(with addresses: [[UInt8]]) {
        let continuation: CheckedContinuation<[[UInt8]], Never>? = state.withLock { state in
            switch state {
            case .pending:
                state = .finished(addresses)
                return nil
            case .waiting(let continuation):
                state = .resumed
                return continuation
            case .finished, .resumed:
                return nil
            }
        }
        continuation?.resume(returning: addresses)
    }
}
