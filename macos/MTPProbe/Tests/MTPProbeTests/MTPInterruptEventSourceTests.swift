import Foundation
import IOKit
import XCTest
@testable import MTPProbeLib

final class MTPInterruptEventSourceTests: XCTestCase {
    private final class Scheduler {
        var jobs: [() -> Void] = []
        func enqueue(_ work: @escaping () -> Void) { jobs.append(work) }
        func run() { if !jobs.isEmpty { jobs.removeFirst()() } }
        func drain() {
            var n = 0
            while !jobs.isEmpty && n < 50 { run(); n += 1 }
            XCTAssertTrue(jobs.isEmpty)
        }
    }
    private enum Failure: Error { case rejected, aborted }
    private final class Pipe: MTPInterruptPipe {
        var submissions = 0
        var aborts = 0
        var failSubmit = false
        var failAbort = false
        var duringSubmit: (() -> Void)?
        var callback: ((Result<Int, Error>) -> Void)?
        var buffer: NSMutableData?
        func enqueue(_ buffer: NSMutableData, completion: @escaping (Result<Int, Error>) -> Void) throws {
            submissions += 1
            if failSubmit { throw Failure.rejected }
            self.buffer = buffer
            callback = completion
            duringSubmit?()
        }
        func abort() throws { aborts += 1; if failAbort { throw Failure.aborted } }
        func finish(_ count: Int = 0) {
            let cb = callback; callback = nil; buffer = nil; cb?(.success(count))
        }
    }
    private final class Rig {
        let scheduler = Scheduler()
        let pipe = Pipe()
        var destroyed = 0
        var errors = 0
        lazy var gate = MTPTransportResourceLifetime(abort: {}, destroy: { [unowned self] in destroyed += 1 }, schedule: { $0() })
        lazy var source = MTPInterruptEventSource(pipe: pipe,
            endpoint: MTPInterruptEndpoint(address: 0x83, bufferSize: 64), lifetime: gate,
            schedule: scheduler.enqueue, reportAbortError: { [unowned self] _ in errors += 1 })
        func submit(_ completion: @escaping (Result<Int, Error>) -> Void = { _ in }) throws {
            try source.submit(into: NSMutableData(length: 64)!, completion: completion)
        }
        func finish() { pipe.finish(); scheduler.drain(); XCTAssertTrue(gate.close(deadline: 0)) }
    }
    private func configuration(_ endpoint: [UInt8] = [7, 5, 0x83, 3, 64, 0, 1], suffix: [UInt8] = []) -> Data {
        Data([9, 2, 25, 0, 1, 1, 0, 0x80, 50, 9, 4, 0, 0, 1, 6, 1, 1, 0] + endpoint + suffix)
    }
    private func discover(_ data: Data) throws -> MTPInterruptEndpoint? {
        try MTPInterruptEndpoint.discover(configuration: data, interface: 0, alternate: 0)
    }

    func testDiscoversInterruptWithoutSelectingBulkOrOUT() throws {
        let data = configuration([7, 5, 0x81, 2, 0, 2, 0, 7, 5, 2, 3, 64, 0, 1, 7, 5, 0x83, 3, 64, 0, 1])
        XCTAssertEqual(try discover(data), MTPInterruptEndpoint(address: 0x83, bufferSize: 64))
    }
    func testMissingAndOtherAlternateEndpoint() throws {
        XCTAssertNil(try discover(configuration([])))
        XCTAssertNil(try MTPInterruptEndpoint.discover(configuration: configuration(), interface: 1, alternate: 0))
    }
    func testInvalidEndpointCharacteristics() {
        for ep: [UInt8] in [[7,5,0x80,3,64,0,1], [7,5,0x83,3,0,0,1], [7,5,0x83,3,1,4,1],
                           [7,5,0x83,3,64,0,0], [7,5,0x83,3,64,0x18,1], [7,5,0x93,3,64,0,1]] {
            XCTAssertThrowsError(try discover(configuration(ep)))
        }
        XCTAssertThrowsError(try discover(configuration([7,5,0x83])))
        XCTAssertThrowsError(try discover(configuration(suffix: [7,5,0x84,3,64,0,1])))
    }
    func testPacketRoundingAndCompanionBound() throws {
        XCTAssertEqual(try discover(configuration([7,5,0x83,3,8,0,1]))?.bufferSize, 24)
        XCTAssertEqual(try discover(configuration([7,5,0x83,3,0,0x14,1]))?.bufferSize, 3072)
        XCTAssertEqual(try discover(configuration(suffix: [6,48,1,0,128,0]))?.bufferSize, 128)
        XCTAssertThrowsError(try discover(configuration(suffix: [6,48,0,0,128,0])))
        XCTAssertThrowsError(try discover(configuration([7,5,0x83,3,0,4,1], suffix: [6,48,15,0,0,64])))
    }
    func testInactiveAndMissingEndpointNeverSubmit() throws {
        let r = Rig()
        XCTAssertTrue(r.source.hasEndpoint)
        r.scheduler.drain(); XCTAssertEqual(r.pipe.submissions, 0)
        let missing = MTPInterruptEventSource(pipe: nil, endpoint: nil, lifetime: r.gate)
        XCTAssertFalse(missing.hasEndpoint)
        XCTAssertThrowsError(try missing.submit(into: NSMutableData(length: 24)!, completion: { _ in }))
        XCTAssertTrue(r.gate.close(deadline: 0))
    }
    func testRejectedSubmissionReleasesLease() throws {
        let r = Rig(); r.pipe.failSubmit = true
        var failed = false
        try r.submit { if case .failure = $0 { failed = true } }
        r.scheduler.drain()
        XCTAssertTrue(failed); XCTAssertEqual(r.pipe.submissions, 1)
        XCTAssertTrue(r.gate.close(deadline: 0)); XCTAssertEqual(r.destroyed, 1)
    }
    func testExactlyOnceCompletionAndLeaseThroughCallback() throws {
        let r = Rig(); var completions = 0
        try r.submit { _ in
            completions += 1
            XCTAssertFalse(r.gate.close(deadline: 0))
            XCTAssertEqual(r.destroyed, 0)
        }
        r.scheduler.drain()
        let duplicate = r.pipe.callback!
        r.pipe.finish(12); duplicate(.success(12)); r.scheduler.drain()
        XCTAssertEqual(completions, 1); XCTAssertEqual(r.destroyed, 1)
    }
    func testDelayedCancellationDoesNotDestroyResources() throws {
        let r = Rig(); try r.submit(); r.scheduler.drain()
        r.source.cancel(); r.scheduler.drain()
        XCTAssertEqual(r.pipe.aborts, 1)
        XCTAssertFalse(r.gate.close(deadline: 0)); XCTAssertEqual(r.destroyed, 0)
        r.finish(); XCTAssertEqual(r.destroyed, 1)
    }
    func testMissingCompletionRemainsPendingUntilExplicitLateCallback() throws {
        let r = Rig(); try r.submit(); r.scheduler.drain()
        r.source.cancel(); r.scheduler.drain()
        for _ in 0..<3 { XCTAssertFalse(r.gate.close(deadline: 0)) }
        XCTAssertEqual(r.gate.cleanupState, .pendingCleanup)
        XCTAssertNotNil(r.pipe.buffer); XCTAssertEqual(r.destroyed, 0)
        // Test cleanup only: simulate callback arriving after an unbounded delay.
        r.finish()
    }
    func testAbortFailureDoesNotReleaseOrRetry() throws {
        let r = Rig(); r.pipe.failAbort = true
        try r.submit(); r.scheduler.drain(); r.source.cancel(); r.source.cancel(); r.scheduler.drain()
        XCTAssertEqual(r.errors, 1); XCTAssertEqual(r.pipe.aborts, 1)
        XCTAssertFalse(r.gate.close(deadline: 0)); XCTAssertEqual(r.pipe.submissions, 1)
        r.finish()
    }
    func testStopBeforeQueuedSubmissionPreventsUSBCall() throws {
        let r = Rig(); try r.submit(); r.source.cancel(); r.scheduler.drain()
        XCTAssertEqual(r.pipe.submissions, 0); XCTAssertEqual(r.pipe.aborts, 0)
        XCTAssertThrowsError(try r.submit()); XCTAssertTrue(r.gate.close(deadline: 0))
    }
    func testStopDuringSubmissionAbortsAfterSubmission() throws {
        let r = Rig(); r.pipe.duringSubmit = { r.source.cancel() }
        try r.submit(); r.scheduler.drain()
        XCTAssertEqual(r.pipe.submissions, 1); XCTAssertEqual(r.pipe.aborts, 1)
        XCTAssertThrowsError(try r.submit()); r.pipe.duringSubmit = nil; r.finish()
    }
    func testSecondPendingReadAndWrongBufferRejected() throws {
        let r = Rig()
        XCTAssertThrowsError(try r.source.submit(into: NSMutableData(length: 24)!, completion: { _ in }))
        try r.submit(); XCTAssertThrowsError(try r.submit())
        r.scheduler.drain(); r.finish()
    }
    func testInvalidCompletionLengthIsFailure() throws {
        let r = Rig(); var failed = false
        try r.submit { if case .failure = $0 { failed = true } }
        r.scheduler.drain(); r.pipe.finish(65); r.scheduler.drain()
        XCTAssertTrue(failed); XCTAssertTrue(r.gate.close(deadline: 0))
    }
    func testClosedLifetimeRejectsSubmission() {
        let r = Rig(); XCTAssertTrue(r.gate.close(deadline: 0))
        XCTAssertThrowsError(try r.submit()); XCTAssertEqual(r.pipe.submissions, 0)
    }
    func testTerminationDuringInitializationLatchesAndDeliversOnceOffQueue() {
        let queue = Scheduler()
        let bridge = MTPUSBTerminationBridge(scheduleInvalidation: queue.enqueue)
        bridge.receive(message: 0xe0000010)
        XCTAssertTrue(bridge.isTerminated)
        var stopped = 0; var invalidated = 0
        bridge.bind(stopAdmission: { stopped += 1 }, invalidate: { invalidated += 1 })
        bridge.receive(message: 0xe0000010)
        XCTAssertEqual(stopped, 1); XCTAssertEqual(invalidated, 0)
        queue.drain(); XCTAssertEqual(invalidated, 1)
    }
    func testUnrelatedInterestDoesNotTerminate() {
        let bridge = MTPUSBTerminationBridge()
        bridge.receive(message: 0)
        XCTAssertFalse(bridge.isTerminated)
    }
    private final class Transport: MTPTransport {
        let bulkOutMaxPacketSize = 512
        var commands = 0
        func write(data: Data, timeout: TimeInterval) throws { commands += 1 }
        func read(maxSize: Int, timeout: TimeInterval) throws -> Data { Data() }
        func abort() {}
        func close() {}
        func isTerminalError(_ error: Error) -> Bool { false }
    }
    func testIdleTerminationInvalidatesDeviceWithoutMTPCommands() {
        let r = Rig(); let queue = Scheduler(); let transport = Transport()
        let device = MTPDevice(transport: transport)
        let observer = MTPEventObserver(source: r.source, lifetime: r.gate, enabled: true,
            schedule: r.scheduler.enqueue, record: { _ in XCTFail("Unexpected event") })
        let bridge = MTPUSBTerminationBridge(scheduleInvalidation: queue.enqueue)
        bridge.bind(source: r.source, observer: observer, device: device)
        bridge.receive(message: 0xe0000010)
        XCTAssertFalse(device.isDisconnected)
        queue.drain(); r.scheduler.drain()
        XCTAssertTrue(device.isDisconnected); XCTAssertEqual(transport.commands, 0)
        observer.start(); r.scheduler.drain(); XCTAssertEqual(r.pipe.submissions, 0)
        XCTAssertTrue(r.gate.close(deadline: 0))
    }
    func testObserverUsesEndpointBufferAndStopPreventsRearm() throws {
        let r = Rig(); var records = 0
        let observer = MTPEventObserver(source: r.source, lifetime: r.gate, enabled: true,
            schedule: r.scheduler.enqueue, record: { _ in records += 1 })
        observer.start(); r.scheduler.drain()
        XCTAssertEqual(r.pipe.buffer?.length, 64)
        let event: [UInt8] = [12,0,0,0,4,0,4,0x40,0xff,0xff,0xff,0xff]
        event.withUnsafeBytes { r.pipe.buffer!.mutableBytes.copyMemory(from: $0.baseAddress!, byteCount: 12) }
        r.pipe.finish(12); r.scheduler.run() // adapter callback queues observer processing
        XCTAssertEqual(records, 0)
        observer.stop(); r.scheduler.drain()
        XCTAssertEqual(r.pipe.submissions, 1); XCTAssertEqual(records, 0)
        XCTAssertTrue(r.gate.close(deadline: 0))
    }
    func testCloseBeforeWorkerSubmissionDoesNotEnqueue() throws {
        let r = Rig(); try r.submit()
        XCTAssertFalse(r.gate.close(deadline: 0))
        r.scheduler.drain()
        XCTAssertEqual(r.pipe.submissions, 0)
        XCTAssertEqual(r.destroyed, 1)
    }
    func testObserverLeaseSurvivesAdapterCompletionUntilProcessing() {
        let r = Rig(); var records = 0
        let observer = MTPEventObserver(source: r.source, lifetime: r.gate, enabled: true,
            schedule: r.scheduler.enqueue, record: { _ in records += 1 })
        observer.start(); r.scheduler.drain()
        let event: [UInt8] = [12,0,0,0,4,0,4,0x40,0xff,0xff,0xff,0xff]
        event.withUnsafeBytes { r.pipe.buffer!.mutableBytes.copyMemory(from: $0.baseAddress!, byteCount: 12) }
        r.pipe.finish(12); r.scheduler.run()
        XCTAssertFalse(r.gate.close(deadline: 0))
        XCTAssertEqual(r.destroyed, 0)
        r.scheduler.run()
        XCTAssertEqual(records, 1); XCTAssertEqual(r.destroyed, 1)
        observer.stop(); r.scheduler.drain()
        XCTAssertEqual(r.pipe.submissions, 1)
    }

}
