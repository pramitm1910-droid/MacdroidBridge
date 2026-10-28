import Foundation

/// Owns the lifetime of a USB interface and its pipes independently of a shutdown caller.
/// Every operation using a pipe must hold a counted lease through its entire I/O call.
final class MTPTransportResourceLifetime {
    enum State: Equatable {
        case open
        case pendingCleanup
        case destroying
        case destroyed
    }

    private let condition = NSCondition()
    private let abortResources: () -> Void
    private let destroyResources: () -> Void
    private let schedule: (@escaping () -> Void) -> Void
    private var state: State = .open
    private var activeIOCount = 0
    private var activeThreads = [ObjectIdentifier: Int]()
    private var asyncLeases = [UUID: MTPAsyncResourceLease]()
    private var abortInFlight = false
    private var abortRequested = false

    init(
        abort: @escaping () -> Void,
        destroy: @escaping () -> Void,
        schedule: @escaping (@escaping () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    ) {
        abortResources = abort
        destroyResources = destroy
        self.schedule = schedule
    }

    var cleanupState: State {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    /// Independent of a thread stack: release explicitly after completion processing.
    /// Retained objects (for example a mutable read buffer) cannot disappear early.
    func acquireAsyncLease(retaining objects: [AnyObject] = []) throws -> MTPAsyncResourceLease {
        condition.lock()
        guard state == .open else {
            condition.unlock()
            throw MTPDeviceError.deviceDisconnected("Transport has been closed")
        }
        activeIOCount += 1
        let id = UUID()
        let lease = MTPAsyncResourceLease(retaining: objects) { [self] in
            condition.lock()
            let completedLease = asyncLeases.removeValue(forKey: id)
            activeIOCount -= 1
            condition.broadcast()
            condition.unlock()
            withExtendedLifetime(completedLease) { finishCleanupIfReady() }
        }
        // Intentional ownership cycle until explicit release, including if the
        // caller drops its token. A lost completion retains resources, never destroys live I/O.
        asyncLeases[id] = lease
        condition.unlock()
        return lease
    }

    func performIO<T>(_ body: () throws -> T) throws -> T {
        let thread = ObjectIdentifier(Thread.current)
        condition.lock()
        guard state == .open else {
            condition.unlock()
            throw MTPDeviceError.deviceDisconnected("Transport has been closed")
        }
        activeIOCount += 1
        activeThreads[thread, default: 0] += 1
        condition.unlock()

        defer { finishIO(on: thread) }
        return try body()
    }

    /// The abort worker is itself a pipe user. Cleanup waits for it as well as I/O.
    func requestAbort() {
        condition.lock()
        let shouldSchedule = !abortRequested && state != .destroyed && state != .destroying
        if shouldSchedule {
            abortRequested = true
            abortInFlight = true
        }
        condition.unlock()

        if shouldSchedule {
            schedule { [self] in
                abortResources()
                condition.lock()
                abortInFlight = false
                if state == .open { abortRequested = false }
                condition.broadcast()
                condition.unlock()
                finishCleanupIfReady()
            }
        }
    }

    /// Returns true only after destruction has completed. A deadline leaves cleanup pending.
    @discardableResult
    func close(deadline: TimeInterval = 2.0) -> Bool {
        condition.lock()
        if state == .open { state = .pendingCleanup }
        condition.unlock()
        requestAbort()
        finishCleanupIfReady()

        let thread = ObjectIdentifier(Thread.current)
        let end = Date().addingTimeInterval(max(0, deadline))
        condition.lock()
        defer { condition.unlock() }
        while state != .destroyed {
            // Waiting for the lease held by this stack would deadlock.
            if (activeThreads[thread] ?? 0) > 0 { return false }
            if !condition.wait(until: end) { return state == .destroyed }
        }
        return true
    }

    private func finishIO(on thread: ObjectIdentifier) {
        condition.lock()
        activeIOCount -= 1
        if let count = activeThreads[thread], count > 1 {
            activeThreads[thread] = count - 1
        } else {
            activeThreads.removeValue(forKey: thread)
        }
        condition.broadcast()
        condition.unlock()
        finishCleanupIfReady()
    }

    private func finishCleanupIfReady() {
        condition.lock()
        guard state == .pendingCleanup && activeIOCount == 0 && !abortInFlight else {
            condition.unlock()
            return
        }
        state = .destroying // Single cleanup claimant, protected by the condition.
        condition.unlock()

        destroyResources()

        condition.lock()
        state = .destroyed
        condition.broadcast()
        condition.unlock()
    }
}
