import Foundation

/// Small synchronous state holder for test callbacks that are `@Sendable`.
/// Tests can update and inspect it without capturing mutable local variables
/// across concurrency domains.
nonisolated final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func update(_ body: (inout Value) -> Void) {
        lock.withLock {
            body(&storage)
        }
    }
}
