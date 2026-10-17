import Foundation

/// Lifecycle states of an MTP device session.
public enum MTPSessionState: Equatable, CustomStringConvertible {
    case closed
    case opening
    case active(sessionID: UInt32)
    case closing
    case failed(description: String)

    public var description: String {
        switch self {
        case .closed: return "closed"
        case .opening: return "opening"
        case .active(let id): return "active(sessionID: \(id))"
        case .closing: return "closing"
        case .failed(let desc): return "failed(\(desc))"
        }
    }
}

/// Errors raised by the MTP session serialization coordinator.
public enum MTPSerializationError: Error, CustomStringConvertible, Equatable {
    case invalidState(current: String, expected: String)
    case sessionPoisoned(reason: String)
    case timedOut(waitedSeconds: TimeInterval)
    case cancelled
    case inFlightTransactionActive
    case sessionNotActive
    case openSessionFailed(String)
    case closeSessionFailed(String)

    public var description: String {
        switch self {
        case .invalidState(let current, let expected):
            return "Invalid MTP session state: \(current) (expected: \(expected))"
        case .sessionPoisoned(let reason):
            return "MTP session is poisoned due to previous failure: \(reason)"
        case .timedOut(let waited):
            return "MTP operation timed out waiting for session access after \(String(format: "%.3f", waited))s"
        case .cancelled:
            return "MTP operation was cancelled while waiting for session access"
        case .inFlightTransactionActive:
            return "Previous MTP transaction is incomplete; refusing to interleave operations"
        case .sessionNotActive:
            return "MTP session is not active"
        case .openSessionFailed(let msg):
            return "OpenSession failed: \(msg)"
        case .closeSessionFailed(let msg):
            return "CloseSession failed: \(msg)"
        }
    }
}

/// Scoped context granted exclusively to the active operation.
/// Manages transaction IDs sequentially without allowing interleaving.
public final class MTPTransactionScope {
    private unowned let coordinator: MTPSessionCoordinator
    public private(set) var inFlightTransactionID: UInt32?
    public private(set) var completedTransactionIDs: [UInt32] = []
    public private(set) var isFinished: Bool = false

    fileprivate init(coordinator: MTPSessionCoordinator) {
        self.coordinator = coordinator
    }

    /// Allocate the next transaction ID for an operation.
    /// Throws if a previous transaction in this scope was not marked completed.
    public func allocateTransactionID() throws -> UInt32 {
        guard !isFinished else {
            throw MTPSerializationError.invalidState(current: "scope finished", expected: "active scope")
        }
        guard inFlightTransactionID == nil else {
            throw MTPSerializationError.inFlightTransactionActive
        }
        let id = coordinator.allocateNextTransactionID()
        inFlightTransactionID = id
        return id
    }

    /// Mark a transaction as completed once its response phase is validated.
    public func completeTransaction(_ id: UInt32) throws {
        guard !isFinished else {
            throw MTPSerializationError.invalidState(current: "scope finished", expected: "active scope")
        }
        guard inFlightTransactionID == id else {
            throw MTPSerializationError.invalidState(
                current: "in-flight transaction \(inFlightTransactionID?.description ?? "none")",
                expected: "transaction \(id)"
            )
        }
        inFlightTransactionID = nil
        completedTransactionIDs.append(id)
    }

    /// Convenience wrapper to run a single transaction to completion.
    public func withTransaction<R>(_ block: (UInt32) throws -> R) throws -> R {
        let id = try allocateTransactionID()
        let result = try block(id)
        try completeTransaction(id)
        return result
    }

    fileprivate func finish() {
        isFinished = true
    }
}

/// Coordinates exclusive access to an MTP session, serializing all USB operations
/// in FIFO order, ensuring compound operation atomicity, and guarding against
/// transaction interleaving or state corruption.
public final class MTPSessionCoordinator {
    private final class Waiter {
        let id = UUID()
        var isReady = false
        var isCancelled = false
        var isPoisoned = false
        var poisonReason = ""
    }

    private let condition = NSCondition()
    private var waiters: [Waiter] = []
    private var isExecuting: Bool = false
    private var executingThread: Thread? = nil
    private var state: MTPSessionState = .closed
    private var transactionAllocator = MTPTransactionIDAllocator()

    public init() {}

    /// Current session lifecycle state.
    public var sessionState: MTPSessionState {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    /// Active session ID if the session is open, or nil otherwise.
    public var sessionID: UInt32? {
        condition.lock()
        defer { condition.unlock() }
        if case .active(let id) = state { return id }
        return nil
    }

    /// Whether the session has failed and is permanently poisoned.
    public var isFailed: Bool {
        condition.lock()
        defer { condition.unlock() }
        if case .failed = state { return true }
        return false
    }

    /// Number of operations currently queued and waiting for session access.
    public var queuedWaiterCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return waiters.count
    }

    /// Whether an operation is currently executing against the session.
    public var isExecutingOperation: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isExecuting
    }

    fileprivate func allocateNextTransactionID() -> UInt32 {
        condition.lock()
        defer { condition.unlock() }
        return transactionAllocator.allocate()
    }

    /// Explicitly mark the session as failed (e.g. following transport drop or framing error).
    /// Poisons all waiting and subsequent operations.
    public func fail(reason: String) {
        condition.lock()
        defer { condition.unlock() }
        state = .failed(description: reason)
        for w in waiters {
            w.isPoisoned = true
            w.poisonReason = reason
        }
        waiters.removeAll()
        isExecuting = false
        executingThread = nil
        condition.broadcast()
    }

    /// Cancel all currently queued operations waiting for session access.
    public func cancelPendingWaiters() {
        condition.lock()
        defer { condition.unlock() }
        for w in waiters {
            w.isCancelled = true
        }
        condition.broadcast()
    }

    /// Execute an OpenSession operation exclusively, establishing a new session state.
    public func openSession(
        timeout: TimeInterval? = nil,
        _ block: (UInt32) throws -> UInt32
    ) throws {
        let scope = try acquireExclusive(timeout: timeout, allowedStateCategory: .closedOnly)
        defer {
            scope.finish()
            releaseExclusive(scope: scope, fatalError: nil)
        }

        do {
            condition.lock()
            state = .opening
            condition.unlock()

            // OpenSession always uses transaction ID 0 per MTP spec §9.3.1
            let establishedID = try block(MTPTransactionIDAllocator.openSessionTransactionID)
            guard establishedID != 0 else {
                throw MTPSerializationError.openSessionFailed("Session ID cannot be 0")
            }

            condition.lock()
            state = .active(sessionID: establishedID)
            transactionAllocator = MTPTransactionIDAllocator()
            condition.unlock()
        } catch {
            condition.lock()
            // If open failed without permanent poisoning, revert to closed so reconnect/retry is possible.
            if case .opening = state {
                state = .closed
            }
            condition.unlock()
            throw error
        }
    }

    /// Execute a CloseSession operation exclusively, returning the session to closed.
    public func closeSession(
        timeout: TimeInterval? = nil,
        _ block: (MTPTransactionScope) throws -> Void
    ) throws {
        condition.lock()
        if case .closed = state {
            condition.unlock()
            return // Idempotent cleanup if already closed
        }
        condition.unlock()

        let scope = try acquireExclusive(timeout: timeout, allowedStateCategory: .activeOnly)
        var fatalError: Error? = nil
        defer {
            scope.finish()
            releaseExclusive(scope: scope, fatalError: fatalError)
        }

        do {
            condition.lock()
            state = .closing
            condition.unlock()

            try block(scope)

            condition.lock()
            state = .closed
            condition.unlock()
        } catch {
            condition.lock()
            state = .failed(description: "CloseSession failed: \(error.localizedDescription)")
            condition.unlock()
            fatalError = error
            throw error
        }
    }

    /// Execute one or more MTP commands atomically. No other operation can interleave
    /// while the block is executing.
    public func perform<T>(
        timeout: TimeInterval? = nil,
        _ block: (MTPTransactionScope) throws -> T
    ) throws -> T {
        let scope = try acquireExclusive(timeout: timeout, allowedStateCategory: .activeOnly)
        var fatalError: Error? = nil
        defer {
            scope.finish()
            releaseExclusive(scope: scope, fatalError: fatalError)
        }

        do {
            let result = try block(scope)
            if scope.inFlightTransactionID != nil {
                let err = MTPSerializationError.inFlightTransactionActive
                fatalError = err
                throw err
            }
            return result
        } catch {
            if scope.inFlightTransactionID != nil {
                fatalError = error
            }
            throw error
        }
    }

    // MARK: - Private Queue Synchronization

    private enum StateCategory {
        case closedOnly
        case activeOnly
    }

    private func acquireExclusive(
        timeout: TimeInterval?,
        allowedStateCategory: StateCategory
    ) throws -> MTPTransactionScope {
        let startTime = Date()
        let deadline = timeout.map { startTime.addingTimeInterval($0) }

        condition.lock()
        defer { condition.unlock() }

        func checkState() throws {
            switch state {
            case .failed(let reason):
                throw MTPSerializationError.sessionPoisoned(reason: reason)
            case .closed:
                if allowedStateCategory != .closedOnly {
                    throw MTPSerializationError.sessionNotActive
                }
            case .opening:
                throw MTPSerializationError.invalidState(current: "opening", expected: "ready")
            case .active:
                if allowedStateCategory != .activeOnly {
                    throw MTPSerializationError.invalidState(current: "active", expected: "closed")
                }
            case .closing:
                throw MTPSerializationError.invalidState(current: "closing", expected: "active")
            }
        }

        // Prevent self-deadlock if an operation attempts to re-enter perform on the same thread
        if isExecuting && executingThread == Thread.current {
            throw MTPSerializationError.invalidState(
                current: "reentrant operation on same thread",
                expected: "cannot nest perform calls; use existing MTPTransactionScope"
            )
        }

        try checkState()

        if !isExecuting && waiters.isEmpty {
            isExecuting = true
            executingThread = Thread.current
            return MTPTransactionScope(coordinator: self)
        }

        let waiter = Waiter()
        waiters.append(waiter)

        while true {
            if waiter.isCancelled {
                waiters.removeAll { $0 === waiter }
                if waiter.isReady {
                    handoffNextWaiterLocked()
                }
                throw MTPSerializationError.cancelled
            }
            if waiter.isPoisoned {
                waiters.removeAll { $0 === waiter }
                if waiter.isReady {
                    handoffNextWaiterLocked()
                }
                throw MTPSerializationError.sessionPoisoned(reason: waiter.poisonReason)
            }
            if waiter.isReady {
                break
            }
            if let deadline {
                let now = Date()
                if now >= deadline {
                    waiters.removeAll { $0 === waiter }
                    throw MTPSerializationError.timedOut(waitedSeconds: now.timeIntervalSince(startTime))
                }
                condition.wait(until: deadline)
            } else {
                condition.wait()
            }
        }

        do {
            try checkState()
            executingThread = Thread.current
            return MTPTransactionScope(coordinator: self)
        } catch {
            handoffNextWaiterLocked()
            throw error
        }
    }

    private func releaseExclusive(scope: MTPTransactionScope, fatalError: Error?) {
        condition.lock()
        defer { condition.unlock() }

        executingThread = nil

        if let fatalError {
            let errorDesc = String(describing: fatalError)
            if case .failed = state {
                // Already marked failed
            } else {
                state = .failed(description: errorDesc)
            }
            for w in waiters {
                w.isPoisoned = true
                w.poisonReason = errorDesc
            }
            waiters.removeAll()
            isExecuting = false
            condition.broadcast()
            return
        }

        handoffNextWaiterLocked()
    }

    private func handoffNextWaiterLocked() {
        executingThread = nil
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            if !next.isCancelled && !next.isPoisoned {
                next.isReady = true
                isExecuting = true
                condition.broadcast()
                return
            }
        }
        isExecuting = false
    }
}
