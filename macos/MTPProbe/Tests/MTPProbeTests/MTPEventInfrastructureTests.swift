import Foundation
import XCTest
@testable import MTPProbeLib

final class MTPEventInfrastructureTests: XCTestCase {
    private func packet(_ code: UInt16 = 0x4004, tx: UInt32 = 0xFFFFFFFF,
                        params: [UInt32] = []) -> Data {
        var w = MTPDataWriter()
        w.writeUInt32(UInt32(12 + params.count * 4))
        w.writeUInt16(4)
        w.writeUInt16(code)
        w.writeUInt32(tx)
        for p in params { w.writeUInt32(p) }
        return w.bytes
    }

    private final class Scheduler {
        var jobs: [() -> Void] = []
        func enqueue(_ job: @escaping () -> Void) { jobs.append(job) }
        func run() { if !jobs.isEmpty { jobs.removeFirst()() } }
        func drain() {
            var count = 0
            while !jobs.isEmpty && count < 100 { run(); count += 1 }
            XCTAssertTrue(jobs.isEmpty, "Unbounded rearm loop")
        }
    }

    private enum MockError: Error { case submission, cancelled }
    private final class Source: MTPEventSource {
        var hasEndpoint = true
        var submissions = 0
        var cancellations = 0
        var failSubmission = false
        var inlineData: Data?
        var buffer: NSMutableData?
        var callback: ((Result<Int, Error>) -> Void)?
        func submit(into buffer: NSMutableData, completion: @escaping (Result<Int, Error>) -> Void) throws {
            XCTAssertNil(callback, "Only one read may be pending")
            submissions += 1
            if failSubmission { throw MockError.submission }
            self.buffer = buffer
            callback = completion
            if let data = inlineData { inlineData = nil; finish(data) }
        }
        func cancel() { cancellations += 1 }
        func finish(_ data: Data) {
            let cb = callback
            data.withUnsafeBytes { raw in
                if !data.isEmpty { buffer!.mutableBytes.copyMemory(from: raw.baseAddress!, byteCount: data.count) }
            }
            callback = nil
            buffer = nil
            cb?(.success(data.count))
        }
        func cancelFinished() {
            let cb = callback
            callback = nil
            buffer = nil
            cb?(.failure(MockError.cancelled))
        }
    }

    private final class Rig {
        let scheduler = Scheduler()
        let source = Source()
        var destroys = 0
        var aborts = 0
        var records: [MTPEventRecord] = []
        var states: [MTPEventObserver.State] = []
        lazy var lifetime = MTPTransportResourceLifetime(abort: { [unowned self] in aborts += 1 },
            destroy: { [unowned self] in destroys += 1 }, schedule: { $0() })
        lazy var observer = MTPEventObserver(source: source, lifetime: lifetime, enabled: true,
            clock: MTPDiagnosticClock(wallNow: { Date(timeIntervalSince1970: 100) }, monotonicNow: { 5 }),
            schedule: scheduler.enqueue, record: { [unowned self] in records.append($0) },
            status: { [unowned self] in states.append($0) })
        func finish() {
            observer.stop()
            scheduler.drain()
            source.cancelFinished()
            scheduler.drain()
            XCTAssertTrue(lifetime.close(deadline: 0))
        }
    }

    func testEventDecodesKnownUnknownAndAllParameters() throws {
        var decoder = MTPEventDecoder()
        XCTAssertEqual(try decoder.feed(packet(0xC123, tx: 7, params: [0, 0x10001, .max])),
                       [MTPEvent(code: 0xC123, transactionID: 7, parameters: [0, 0x10001, .max])])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testEveryFragmentBoundaryAndCoalescedEvents() throws {
        let first = packet(params: [0x10001])
        let second = packet(0x4005)
        for split in 0...first.count {
            var decoder = MTPEventDecoder()
            let a = try decoder.feed(Data(first.prefix(split)))
            let b = try decoder.feed(Data(first.dropFirst(split)) + second)
            XCTAssertEqual((a + b).map(\.code), [0x4004, 0x4005])
            XCTAssertEqual(decoder.bufferedByteCount, 0)
        }
    }

    func testMalformedLengthsTypesAndAlignmentPoisonDecoder() {
        for length: UInt32 in [0, 11, 13, 25, .max] {
            var decoder = MTPEventDecoder()
            var w = MTPDataWriter(); w.writeUInt32(length)
            XCTAssertThrowsError(try decoder.feed(w.bytes))
            XCTAssertEqual(decoder.bufferedByteCount, 0)
            XCTAssertThrowsError(try decoder.feed(packet()))
        }
        var decoder = MTPEventDecoder()
        var data = packet(); data[4] = 2
        XCTAssertThrowsError(try decoder.feed(data))
    }

    func testOversizedInputRejectedWithoutBufferGrowth() throws {
        var decoder = MTPEventDecoder()
        _ = try decoder.feed(Data(packet(params: [1]).prefix(15)))
        XCTAssertEqual(decoder.bufferedByteCount, 15)
        XCTAssertThrowsError(try decoder.feed(Data(repeating: 0, count: 4097)))
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testManyCoalescedEventsStayBounded() throws {
        var decoder = MTPEventDecoder()
        let data = (0..<300).reduce(into: Data()) { data, _ in data.append(packet()) }
        XCTAssertEqual(try decoder.feed(data).count, 300)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testAsyncLeaseRetainsBufferAndDefersCleanupUntilExplicitRelease() throws {
        let rig = Rig()
        var buffer: NSMutableData? = NSMutableData(length: 24)
        weak var weakBuffer = buffer
        let lease = try rig.lifetime.acquireAsyncLease(retaining: [buffer!])
        buffer = nil
        XCTAssertNotNil(weakBuffer)
        XCTAssertFalse(rig.lifetime.close(deadline: 0))
        XCTAssertEqual(rig.destroys, 0)
        XCTAssertThrowsError(try rig.lifetime.acquireAsyncLease())
        lease.release()
        lease.release()
        XCTAssertNil(weakBuffer)
        XCTAssertEqual(rig.destroys, 1)
    }

    func testConcurrentLeaseReleaseIsExactlyOnce() throws {
        let rig = Rig()
        let lease = try rig.lifetime.acquireAsyncLease()
        XCTAssertFalse(rig.lifetime.close(deadline: 0))
        DispatchQueue.concurrentPerform(iterations: 32) { _ in lease.release() }
        XCTAssertEqual(rig.destroys, 1)
    }

    func testSubmissionFailureReleasesLeaseAndDoesNotRetry() {
        let rig = Rig(); rig.source.failSubmission = true
        rig.observer.start(); rig.scheduler.drain()
        XCTAssertEqual(rig.states.last, .failed)
        XCTAssertEqual(rig.source.submissions, 1)
        XCTAssertTrue(rig.lifetime.close(deadline: 0))
        XCTAssertEqual(rig.destroys, 1)
    }

    func testDelayedCancellationProtectsResourcesUntilCompletionProcessing() {
        let rig = Rig()
        rig.observer.start(); rig.scheduler.drain()
        rig.observer.stop(); rig.observer.stop(); rig.scheduler.drain()
        XCTAssertEqual(rig.source.cancellations, 1)
        XCTAssertFalse(rig.lifetime.close(deadline: 0))
        XCTAssertEqual(rig.destroys, 0)
        rig.source.cancelFinished()
        XCTAssertEqual(rig.destroys, 0, "Callback queued, but processing still owns the lease")
        rig.scheduler.drain()
        XCTAssertEqual(rig.destroys, 1)
        XCTAssertEqual(rig.source.submissions, 1)
        XCTAssertTrue(rig.records.isEmpty)
    }

    func testCompletionBeforeStopCannotRearmPastQueuedStop() {
        let rig = Rig()
        rig.observer.start(); rig.scheduler.drain()
        rig.source.finish(packet())
        rig.observer.stop()
        rig.scheduler.drain()
        XCTAssertEqual(rig.records.count, 0, "Stop latch suppresses queued delivery")
        XCTAssertEqual(rig.source.submissions, 1)
        rig.finish()
    }

    func testStopBeforeCompletionSuppressesLateEvents() {
        let rig = Rig()
        rig.observer.start(); rig.scheduler.drain()
        rig.observer.stop()
        rig.source.finish(packet())
        rig.scheduler.drain()
        XCTAssertTrue(rig.records.isEmpty)
        XCTAssertEqual(rig.source.submissions, 1)
        rig.finish()
    }

    func testTerminationIsIdempotentAndCannotRestart() {
        let rig = Rig()
        rig.observer.start(); rig.scheduler.drain()
        rig.observer.terminate(); rig.observer.terminate(); rig.observer.start()
        rig.scheduler.drain()
        XCTAssertEqual(rig.states.last, .terminated)
        XCTAssertEqual(rig.source.cancellations, 1)
        rig.source.finish(packet())
        rig.scheduler.drain()
        XCTAssertTrue(rig.records.isEmpty)
        XCTAssertEqual(rig.source.submissions, 1)
        rig.finish()
    }

    func testStopBeforeStartMakesNoSubmission() {
        let rig = Rig()
        rig.observer.stop(); rig.observer.start(); rig.scheduler.drain()
        XCTAssertEqual(rig.source.submissions, 0)
        rig.finish()
    }

    func testMissingEndpointAndDisabledObserverMakeNoSubmission() {
        let rig = Rig(); rig.source.hasEndpoint = false
        rig.observer.start(); rig.scheduler.drain()
        XCTAssertEqual(rig.states.last, .unavailable)
        let disabled = MTPEventObserver(source: rig.source, lifetime: rig.lifetime, enabled: false,
            schedule: rig.scheduler.enqueue, record: { _ in XCTFail("Disabled") })
        disabled.start(); rig.scheduler.drain()
        XCTAssertEqual(rig.source.submissions, 0)
        rig.finish()
    }

    func testInlineCompletionAndDuplicateCallbackReleaseOnce() {
        let rig = Rig(); rig.source.inlineData = packet()
        rig.observer.start()
        rig.scheduler.run() // submit returns; inline callback is only queued
        XCTAssertTrue(rig.records.isEmpty)
        rig.scheduler.run() // completion processing before stop
        rig.observer.stop(); rig.scheduler.drain()
        XCTAssertEqual(rig.records.count, 1)
        XCTAssertEqual(rig.source.submissions, 1)
        rig.finish()

        let second = Rig()
        second.observer.start(); second.scheduler.drain()
        let duplicate = second.source.callback!
        second.source.finish(packet())
        duplicate(.success(12))
        second.scheduler.run() // first completion
        second.observer.stop(); second.scheduler.drain()
        XCTAssertEqual(second.records.count, 1)
        second.finish()
        XCTAssertEqual(second.destroys, 1)
    }

    func testEventOnlyProducesRecordAndOnePendingReadWithoutCommands() {
        // The source protocol has no command/write method; no MTPDevice or allocator is supplied.
        let rig = Rig()
        rig.observer.start(); rig.observer.start(); rig.scheduler.drain()
        rig.source.finish(packet(0x4004, tx: 999, params: [0x10001]))
        rig.scheduler.drain()
        XCTAssertEqual(rig.records.map(\.event), [MTPEvent(code: 0x4004, transactionID: 999, parameters: [0x10001])])
        XCTAssertEqual(rig.records.first?.timestamp, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(rig.records.first?.elapsed, 0)
        XCTAssertEqual(rig.source.submissions, 2) // next passive read only
        rig.finish()
    }

    func testMalformedAndZeroByteReadStopWithoutRetry() {
        for data in [Data(), Data([0, 0, 0, 0])] {
            let rig = Rig()
            rig.observer.start(); rig.scheduler.drain()
            rig.source.finish(data); rig.scheduler.drain()
            XCTAssertEqual(rig.states.last, .failed)
            XCTAssertEqual(rig.source.submissions, 1)
            rig.finish()
        }
    }

    func testCloseBetweenCompletionAndRearmRejectsNewLease() {
        let rig = Rig()
        rig.observer.start(); rig.scheduler.drain()
        rig.source.finish(packet())
        rig.scheduler.run() // completion releases old lease, queues rearm
        XCTAssertTrue(rig.lifetime.close(deadline: 0))
        rig.scheduler.drain()
        XCTAssertEqual(rig.states.last, .failed)
        XCTAssertEqual(rig.source.submissions, 1)
        XCTAssertEqual(rig.destroys, 1)
    }

    func testStopLatchSuppressesAlreadyQueuedRearm() {
        let rig = Rig()
        rig.observer.start(); rig.scheduler.drain()
        rig.source.finish(packet())
        rig.scheduler.run() // rearm queued before stop's control message
        rig.observer.stop()
        rig.scheduler.drain()
        XCTAssertEqual(rig.source.submissions, 1)
        rig.finish()
    }

    func testDroppedExternalLeaseStillProtectsResourcesUntilCompletionOwnerReleases() throws {
        let rig = Rig()
        var lease: MTPAsyncResourceLease? = try rig.lifetime.acquireAsyncLease()
        weak var completionLease = lease
        lease = nil
        XCTAssertNotNil(completionLease, "Gate retains the explicit lease")
        XCTAssertFalse(rig.lifetime.close(deadline: 0))
        XCTAssertEqual(rig.destroys, 0)
        completionLease?.release()
        XCTAssertEqual(rig.destroys, 1)
        XCTAssertNil(completionLease)
    }

    func testAsyncCompletionBeforeDelayedAbortDoesNotDestroy() throws {
        let scheduler = Scheduler()
        var destroyed = 0
        let gate = MTPTransportResourceLifetime(abort: {}, destroy: { destroyed += 1 }, schedule: scheduler.enqueue)
        let lease = try gate.acquireAsyncLease()
        XCTAssertFalse(gate.close(deadline: 0))
        lease.release()
        XCTAssertEqual(destroyed, 0)
        scheduler.drain()
        XCTAssertEqual(destroyed, 1)
    }

    func testCloseFromRecordDoesNotDestroyWhileCallbackProcessing() {
        let rig = Rig()
        let observer = MTPEventObserver(source: rig.source, lifetime: rig.lifetime, enabled: true,
            schedule: rig.scheduler.enqueue, record: { _ in
                XCTAssertFalse(rig.lifetime.close(deadline: 0))
                XCTAssertEqual(rig.destroys, 0)
            })
        observer.start(); rig.scheduler.drain()
        rig.source.finish(packet()); rig.scheduler.drain()
        XCTAssertEqual(rig.destroys, 1)
        XCTAssertEqual(rig.source.submissions, 1)
    }
}
