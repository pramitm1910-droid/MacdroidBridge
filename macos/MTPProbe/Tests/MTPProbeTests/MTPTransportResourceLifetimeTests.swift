import Foundation
import XCTest
@testable import MTPProbeLib

final class MTPTransportResourceLifetimeTests: XCTestCase {
    private final class Events {
        private let lock = NSLock()
        private var aborts = 0
        private var destroys = 0

        var counts: (aborts: Int, destroys: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (aborts, destroys)
        }

        func abort() {
            lock.lock()
            aborts += 1
            lock.unlock()
        }

        func destroy() {
            lock.lock()
            destroys += 1
            lock.unlock()
        }
    }

    func testDelayedAbortAndShutdownTimeoutDeferDestructionUntilBothUsersExit() {
        let events = Events()
        let ioEntered = DispatchSemaphore(value: 0)
        let releaseIO = DispatchSemaphore(value: 0)
        let abortEntered = DispatchSemaphore(value: 0)
        let releaseAbort = DispatchSemaphore(value: 0)
        let ioDone = DispatchSemaphore(value: 0)
        let destroyed = DispatchSemaphore(value: 0)
        let lifetime = MTPTransportResourceLifetime(abort: {
            events.abort()
            abortEntered.signal()
            _ = releaseAbort.wait(timeout: .now() + 3)
        }, destroy: {
            events.destroy()
            destroyed.signal()
        })

        DispatchQueue.global().async {
            try? lifetime.performIO {
                ioEntered.signal()
                _ = releaseIO.wait(timeout: .now() + 3)
            }
            ioDone.signal()
        }
        XCTAssertEqual(ioEntered.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(lifetime.close(deadline: 0.02))
        XCTAssertEqual(abortEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(lifetime.cleanupState, .pendingCleanup)
        XCTAssertEqual(events.counts.destroys, 0)

        releaseIO.signal()
        XCTAssertEqual(ioDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(events.counts.destroys, 0, "Abort worker still owns the pipes")
        releaseAbort.signal()
        XCTAssertEqual(destroyed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(events.counts.destroys, 1)
        XCTAssertTrue(lifetime.close(deadline: 0))
    }

    func testConcurrentShutdownClaimsCleanupOnce() {
        let events = Events()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let ioDone = DispatchSemaphore(value: 0)
        let destroyed = DispatchSemaphore(value: 0)
        let lifetime = MTPTransportResourceLifetime(abort: { events.abort() }, destroy: {
            events.destroy()
            destroyed.signal()
        })
        DispatchQueue.global().async {
            try? lifetime.performIO {
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
            }
            ioDone.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)

        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                XCTAssertFalse(lifetime.close(deadline: 0.02))
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(events.counts.destroys, 0)
        release.signal()
        XCTAssertEqual(ioDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(destroyed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(events.counts.aborts, 1)
        XCTAssertEqual(events.counts.destroys, 1)
    }

    func testShutdownFromActiveIOThreadReturnsPendingWithoutDeadlock() throws {
        let events = Events()
        let lifetime = MTPTransportResourceLifetime(
            abort: { events.abort() },
            destroy: { events.destroy() },
            schedule: { $0() }
        )
        try lifetime.performIO {
            XCTAssertFalse(lifetime.close(deadline: 0.02))
            XCTAssertEqual(lifetime.cleanupState, .pendingCleanup)
            XCTAssertEqual(events.counts.destroys, 0)
        }
        XCTAssertEqual(lifetime.cleanupState, .destroyed)
        XCTAssertEqual(events.counts.destroys, 1)
    }

    func testNewIOIsRejectedDuringShutdownAndFailedIOTriggersCleanup() {
        let events = Events()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let destroyed = DispatchSemaphore(value: 0)
        let lifetime = MTPTransportResourceLifetime(abort: { events.abort() }, destroy: {
            events.destroy()
            destroyed.signal()
        })
        DispatchQueue.global().async {
            do {
                try lifetime.performIO {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 3)
                    throw NSError(domain: "mock USB", code: 1)
                }
                XCTFail("Expected mock I/O failure")
            } catch {
                // The failing I/O must release its lease before this thread exits.
            }
            done.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(lifetime.close(deadline: 0.02))
        XCTAssertThrowsError(try lifetime.performIO { XCTFail("I/O must not start") }) { error in
            guard case MTPDeviceError.deviceDisconnected = error else {
                return XCTFail("Expected deviceDisconnected, got \(error)")
            }
        }
        XCTAssertEqual(events.counts.destroys, 0)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(destroyed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(events.counts.destroys, 1)
    }

    func testIOCompletesImmediatelyAfterShutdownStarts() {
        let events = Events()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let lifetime = MTPTransportResourceLifetime(abort: {
            events.abort()
            release.signal()
        }, destroy: { events.destroy() })
        DispatchQueue.global().async {
            try? lifetime.performIO {
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
            }
            done.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(lifetime.close(deadline: 1))
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(events.counts.destroys, 1)
    }
}
