import Foundation
import XCTest
@testable import MTPProbeLib

final class MTPSessionCoordinatorTests: XCTestCase {

    // Helper to open a test session on a coordinator
    private func openTestSession(on coordinator: MTPSessionCoordinator, sessionID: UInt32 = 1) throws {
        try coordinator.openSession { txID in
            XCTAssertEqual(txID, MTPTransactionIDAllocator.openSessionTransactionID)
            return sessionID
        }
    }

    // MARK: - Session Transitions

    func testInitialStateIsClosed() {
        let coordinator = MTPSessionCoordinator()
        XCTAssertEqual(coordinator.sessionState, .closed)
        XCTAssertNil(coordinator.sessionID)
        XCTAssertFalse(coordinator.isFailed)
        XCTAssertEqual(coordinator.queuedWaiterCount, 0)
        XCTAssertFalse(coordinator.isExecutingOperation)
    }

    func testPerformOnClosedSessionThrowsSessionNotActive() {
        let coordinator = MTPSessionCoordinator()
        XCTAssertThrowsError(try coordinator.perform { _ in }) { error in
            XCTAssertEqual(error as? MTPSerializationError, .sessionNotActive)
        }
    }

    func testOpenSessionTransitionsToActive() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator, sessionID: 42)
        XCTAssertEqual(coordinator.sessionState, .active(sessionID: 42))
        XCTAssertEqual(coordinator.sessionID, 42)
        XCTAssertFalse(coordinator.isFailed)
    }

    func testOpenSessionTwiceRejectsInvalidTransition() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator, sessionID: 1)
        XCTAssertThrowsError(try openTestSession(on: coordinator, sessionID: 2)) { error in
            guard case MTPSerializationError.invalidState(let current, _) = error else {
                return XCTFail("Expected invalidState error, got \(error)")
            }
            XCTAssertTrue(current.contains("active"))
        }
    }

    func testCloseSessionTransitionsToClosed() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator, sessionID: 1)
        try coordinator.closeSession { scope in
            let txID = try scope.allocateTransactionID()
            XCTAssertEqual(txID, 1)
            try scope.completeTransaction(txID)
        }
        XCTAssertEqual(coordinator.sessionState, .closed)
        XCTAssertNil(coordinator.sessionID)
    }

    func testCloseSessionWhenAlreadyClosedIsSafeNoop() throws {
        let coordinator = MTPSessionCoordinator()
        XCTAssertNoThrow(try coordinator.closeSession { _ in })
        XCTAssertEqual(coordinator.sessionState, .closed)
    }

    // MARK: - Transaction ID Monotonicity

    func testTransactionIDsAreMonotonicallyIncreasing() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator)

        var lastID: UInt32 = 0
        for i in 1...50 {
            try coordinator.perform { scope in
                let txID = try scope.allocateTransactionID()
                XCTAssertEqual(txID, UInt32(i))
                XCTAssertGreaterThan(txID, lastID)
                lastID = txID
                try scope.completeTransaction(txID)
            }
        }
    }

    func testCannotAllocateMultipleInFlightTransactionsInSameScope() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator)

        XCTAssertThrowsError(try coordinator.perform { scope in
            _ = try scope.allocateTransactionID()
            _ = try scope.allocateTransactionID() // Second without completing first
        }) { error in
            XCTAssertEqual(error as? MTPSerializationError, .inFlightTransactionActive)
        }
    }

    // MARK: - Exclusivity & Serialization Ordering

    func testConcurrentSubmissionsAreStrictlySerialized() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator)

        let operationCount = 20
        let group = DispatchGroup()
        let lock = NSLock()

        var executionLog: [(id: Int, start: Date, end: Date, txID: UInt32)] = []
        var errors: [Error] = []

        for i in 0..<operationCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try coordinator.perform { scope in
                        let start = Date()
                        let txID = try scope.allocateTransactionID()
                        // Artificial delay simulating USB I/O
                        Thread.sleep(forTimeInterval: 0.005)
                        try scope.completeTransaction(txID)
                        let end = Date()

                        lock.lock()
                        executionLog.append((id: i, start: start, end: end, txID: txID))
                        lock.unlock()
                    }
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.wait()
        XCTAssertTrue(errors.isEmpty, "All operations must succeed without error")
        XCTAssertEqual(executionLog.count, operationCount)

        // Verify strict non-overlapping execution (exclusivity)
        // Sort log by start time
        let sorted = executionLog.sorted { $0.start < $1.start }
        for idx in 0..<(sorted.count - 1) {
            let current = sorted[idx]
            let next = sorted[idx + 1]
            XCTAssertLessThanOrEqual(current.end, next.start, "Operation \(current.id) overlapped with operation \(next.id)")
        }

        // Verify transaction IDs were allocated in sequential, monotonic order
        let txIDs = sorted.map { $0.txID }
        XCTAssertEqual(txIDs, Array(1...UInt32(operationCount)))
    }

    // MARK: - Compound Operation Exclusivity

    func testCompoundOperationRemainsAtomicAgainstConcurrentRequests() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator)

        let group = DispatchGroup()
        let lock = NSLock()
        var trace: [String] = []

        // Start compound operation with 3 sub-transactions and artificial pauses
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try coordinator.perform { scope in
                    lock.lock()
                    trace.append("compound-step-1")
                    lock.unlock()
                    let tx1 = try scope.allocateTransactionID()
                    Thread.sleep(forTimeInterval: 0.02)
                    try scope.completeTransaction(tx1)

                    lock.lock()
                    trace.append("compound-step-2")
                    lock.unlock()
                    let tx2 = try scope.allocateTransactionID()
                    Thread.sleep(forTimeInterval: 0.02)
                    try scope.completeTransaction(tx2)

                    lock.lock()
                    trace.append("compound-step-3")
                    lock.unlock()
                    let tx3 = try scope.allocateTransactionID()
                    Thread.sleep(forTimeInterval: 0.01)
                    try scope.completeTransaction(tx3)
                }
            } catch {
                XCTFail("Compound operation failed: \(error)")
            }
            group.leave()
        }

        // Give the compound operation a microsecond head start to begin
        Thread.sleep(forTimeInterval: 0.005)

        // Launch concurrent individual operations while compound is running
        for i in 1...5 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try coordinator.perform { scope in
                        let tx = try scope.allocateTransactionID()
                        lock.lock()
                        trace.append("single-\(i)")
                        lock.unlock()
                        try scope.completeTransaction(tx)
                    }
                } catch {
                    XCTFail("Single operation \(i) failed: \(error)")
                }
                group.leave()
            }
        }

        group.wait()

        // Verify compound steps 1, 2, 3 executed consecutively without ANY single-X intervening
        let step1 = trace.firstIndex(of: "compound-step-1")!
        let step2 = trace.firstIndex(of: "compound-step-2")!
        let step3 = trace.firstIndex(of: "compound-step-3")!

        XCTAssertEqual(step2, step1 + 1, "Compound step 2 must immediately follow step 1 without interleaved commands")
        XCTAssertEqual(step3, step2 + 1, "Compound step 3 must immediately follow step 2 without interleaved commands")
    }

    // MARK: - Failure Cleanup & Session Poisoning

    func testUncompletedTransactionInFlightPoisonsSession() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator)

        enum TestError: Error, CustomStringConvertible {
            case simulatedTransportCrash
            var description: String { "simulatedTransportCrash" }
        }

        // Operation throws before completing transaction
        XCTAssertThrowsError(try coordinator.perform { scope in
            _ = try scope.allocateTransactionID()
            throw TestError.simulatedTransportCrash
        })

        // Coordinator must be poisoned
        XCTAssertTrue(coordinator.isFailed)
        if case .failed(let reason) = coordinator.sessionState {
            XCTAssertTrue(reason.contains("simulatedTransportCrash") || reason.contains("incomplete"))
        } else {
            XCTFail("Session should be in failed state")
        }

        // Any subsequent operation must immediately fail without executing
        var executed = false
        XCTAssertThrowsError(try coordinator.perform { _ in executed = true }) { error in
            guard case MTPSerializationError.sessionPoisoned = error else {
                return XCTFail("Expected sessionPoisoned error, got \(error)")
            }
        }
        XCTAssertFalse(executed)
    }

    func testExplicitFailPoisonsActiveAndQueuedOperations() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator)

        let group = DispatchGroup()
        let lock = NSLock()
        var waiterErrors: [Error] = []

        // Hold coordinator in Thread 1
        let firstHolding = XCTestExpectation(description: "first operation holding")
        let canRelease = XCTestExpectation(description: "first operation can finish")

        group.enter()
        DispatchQueue.global().async {
            do {
                try coordinator.perform { _ in
                    firstHolding.fulfill()
                    self.wait(for: [canRelease], timeout: 2.0)
                }
            } catch {
                // Expected to finish or fail
            }
            group.leave()
        }

        wait(for: [firstHolding], timeout: 1.0)

        // Queue Thread 2 behind Thread 1
        group.enter()
        DispatchQueue.global().async {
            do {
                try coordinator.perform { _ in
                    XCTFail("Queued operation should not run after poisoning")
                }
            } catch {
                lock.lock()
                waiterErrors.append(error)
                lock.unlock()
            }
            group.leave()
        }

        // Wait a tiny moment for Thread 2 to queue
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(coordinator.queuedWaiterCount, 1)

        // Simulate fatal decoder failure
        coordinator.fail(reason: "MTP receive framing failed")

        canRelease.fulfill()
        group.wait()

        XCTAssertTrue(coordinator.isFailed)
        XCTAssertEqual(waiterErrors.count, 1)
        guard case MTPSerializationError.sessionPoisoned(let reason) = waiterErrors[0] else {
            return XCTFail("Expected sessionPoisoned, got \(waiterErrors[0])")
        }
        XCTAssertTrue(reason.contains("framing failed"))
    }

    // MARK: - Cancellation & Timeout

    func testQueuedOperationTimesOutWithoutCorruptingActiveOperation() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator)

        let firstStarted = XCTestExpectation(description: "first started")
        let firstDone = XCTestExpectation(description: "first done")

        DispatchQueue.global().async {
            do {
                try coordinator.perform { scope in
                    let tx = try scope.allocateTransactionID()
                    firstStarted.fulfill()
                    Thread.sleep(forTimeInterval: 0.1) // hold for 100ms
                    try scope.completeTransaction(tx)
                }
                firstDone.fulfill()
            } catch {
                XCTFail("First operation failed: \(error)")
            }
        }

        wait(for: [firstStarted], timeout: 1.0)

        // Second operation specifies a short 20ms timeout
        XCTAssertThrowsError(try coordinator.perform(timeout: 0.02) { _ in
            XCTFail("Should not execute because it timed out")
        }) { error in
            guard case MTPSerializationError.timedOut = error else {
                return XCTFail("Expected timedOut error, got \(error)")
            }
        }

        wait(for: [firstDone], timeout: 1.0)
        XCTAssertFalse(coordinator.isFailed, "Timeout of a waiting operation must not fail the session")

        // Next operation after timeout succeeds cleanly
        var succeeded = false
        try coordinator.perform { scope in
            let tx = try scope.allocateTransactionID()
            try scope.completeTransaction(tx)
            succeeded = true
        }
        XCTAssertTrue(succeeded)
    }

    func testCancelPendingWaitersWakesQueuedOperations() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator)

        let holding = XCTestExpectation(description: "holding")
        let canRelease = XCTestExpectation(description: "can release")
        let group = DispatchGroup()
        let lock = NSLock()
        var cancelledErrors: [Error] = []

        // Thread 1 holds coordinator
        group.enter()
        DispatchQueue.global().async {
            _ = try? coordinator.perform { _ in
                holding.fulfill()
                self.wait(for: [canRelease], timeout: 2.0)
            }
            group.leave()
        }

        wait(for: [holding], timeout: 1.0)

        // Queue 3 threads
        for _ in 1...3 {
            group.enter()
            DispatchQueue.global().async {
                do {
                    try coordinator.perform { _ in
                        XCTFail("Cancelled operation should not run")
                    }
                } catch {
                    lock.lock()
                    cancelledErrors.append(error)
                    lock.unlock()
                }
                group.leave()
            }
        }

        Thread.sleep(forTimeInterval: 0.03)
        XCTAssertEqual(coordinator.queuedWaiterCount, 3)

        // Cancel all pending waiters
        coordinator.cancelPendingWaiters()

        canRelease.fulfill()
        group.wait()

        XCTAssertEqual(cancelledErrors.count, 3)
        for err in cancelledErrors {
            XCTAssertEqual(err as? MTPSerializationError, .cancelled)
        }
        XCTAssertFalse(coordinator.isFailed, "Cancellation of waiters does not poison the session")
    }

    // MARK: - Re-entrancy & Callback Safety

    func testNoLockHeldDuringCallbackAllowsReentrantStateQuery() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator, sessionID: 7)

        var querySucceeded = false
        try coordinator.perform { scope in
            let tx = try scope.allocateTransactionID()
            // Query coordinator state from inside the operation block
            XCTAssertEqual(coordinator.sessionState, .active(sessionID: 7))
            XCTAssertEqual(coordinator.sessionID, 7)
            XCTAssertTrue(coordinator.isExecutingOperation)
            XCTAssertEqual(coordinator.queuedWaiterCount, 0)
            querySucceeded = true
            try scope.completeTransaction(tx)
        }
        XCTAssertTrue(querySucceeded)
    }

    func testReentrantPerformThrowsInsteadOfDeadlocking() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator, sessionID: 10)

        var caughtReentrantError = false
        try coordinator.perform { scope in
            let tx = try scope.allocateTransactionID()
            // Attempt to re-enter perform on the same thread without using scope
            XCTAssertThrowsError(try coordinator.perform { _ in
                XCTFail("Reentrant perform should not execute")
            }) { error in
                guard case MTPSerializationError.invalidState(let current, _) = error else {
                    return XCTFail("Expected invalidState error, got \(error)")
                }
                XCTAssertTrue(current.contains("reentrant"))
                caughtReentrantError = true
            }
            try scope.completeTransaction(tx)
        }
        XCTAssertTrue(caughtReentrantError)
    }

    func testEscapedTransactionScopeCannotBeUsedAfterBlockCompletes() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator, sessionID: 11)

        var escapedScope: MTPTransactionScope?
        try coordinator.perform { scope in
            let tx = try scope.allocateTransactionID()
            try scope.completeTransaction(tx)
            escapedScope = scope
        }

        guard let scope = escapedScope else {
            return XCTFail("Expected scope to be captured")
        }
        XCTAssertTrue(scope.isFinished)

        // Attempting to allocate on the escaped scope must throw invalidState
        XCTAssertThrowsError(try scope.allocateTransactionID()) { error in
            guard case MTPSerializationError.invalidState(let current, _) = error else {
                return XCTFail("Expected invalidState error, got \(error)")
            }
            XCTAssertTrue(current.contains("scope finished"))
        }
    }

    func testOwnershipHandoffWhenSessionClosedDuringQueueing() throws {
        let coordinator = MTPSessionCoordinator()
        try openTestSession(on: coordinator, sessionID: 12)

        let holdGroup = DispatchGroup()
        let closeGroup = DispatchGroup()
        let performGroup = DispatchGroup()
        let holdStarted = XCTestExpectation(description: "hold started")
        let canFinishHold = XCTestExpectation(description: "can finish hold")
        var performError: Error?

        // Thread 1 holds an active operation
        holdGroup.enter()
        DispatchQueue.global().async {
            do {
                try coordinator.perform { scope in
                    holdStarted.fulfill()
                    self.wait(for: [canFinishHold], timeout: 2.0)
                    let tx = try scope.allocateTransactionID()
                    try scope.completeTransaction(tx)
                }
            } catch {
                XCTFail("Hold perform failed: \(error)")
            }
            holdGroup.leave()
        }

        wait(for: [holdStarted], timeout: 1.0)

        // Thread 2 queues closeSession while session is active
        closeGroup.enter()
        DispatchQueue.global().async {
            do {
                try coordinator.closeSession { scope in
                    let tx = try scope.allocateTransactionID()
                    try scope.completeTransaction(tx)
                }
            } catch {
                XCTFail("CloseSession failed: \(error)")
            }
            closeGroup.leave()
        }

        // Thread 3 queues perform behind closeSession while session is still active
        performGroup.enter()
        DispatchQueue.global().async {
            do {
                try coordinator.perform { _ in
                    XCTFail("Perform should not run after closeSession")
                }
            } catch {
                performError = error
            }
            performGroup.leave()
        }

        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(coordinator.queuedWaiterCount, 2)

        // Release Thread 1; Thread 2 runs closeSession and closes the session; Thread 3 wakes to closed session
        canFinishHold.fulfill()
        holdGroup.wait()
        closeGroup.wait()
        performGroup.wait()

        XCTAssertEqual(coordinator.sessionState, .closed)
        XCTAssertEqual(performError as? MTPSerializationError, .sessionNotActive)
        XCTAssertFalse(coordinator.isExecutingOperation, "isExecuting must be false after failed handoff")

        // Crucial test: future openSession must NOT hang or deadlock due to leaked execution ownership
        var reopenSucceeded = false
        try coordinator.openSession { _ in
            reopenSucceeded = true
            return 99
        }
        XCTAssertTrue(reopenSucceeded)
        XCTAssertEqual(coordinator.sessionState, .active(sessionID: 99))
    }
}
