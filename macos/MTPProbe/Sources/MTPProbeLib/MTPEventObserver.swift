import Foundation

/// Diagnostic event-source boundary; normal bulk traffic never uses it.
/// submit/cancel must return promptly and are invoked on one serial control queue.
/// A missing completion intentionally leaves the lease pending. A throwing
/// submit owns no pending I/O. Completion may be inline; after invoking it the
/// source must no longer touch the buffer and must discard its completion closure.
/// cancel must not wait for completion.
protocol MTPEventSource: AnyObject {
    var hasEndpoint: Bool { get }
    var transferBufferSize: Int { get }
    func submit(into buffer: NSMutableData, completion: @escaping (Result<Int, Error>) -> Void) throws
    func cancel()
}

extension MTPEventSource {
    var transferBufferSize: Int { MTPEventDecoder.maximumContainerBytes }
}

struct MTPEventRecord {
    let event: MTPEvent
    let timestamp: Date
    let elapsed: TimeInterval
}

/// All state and callbacks are serialized by schedule, which MUST enqueue work
/// serially (never inline). stop/terminate latch immediately and enqueue cancellation.
/// A read claimed before the latch may finish submission, then gets cancelled on
/// the same queue. Nothing claimed after the latch can submit or rearm. No
/// MTPDevice, coordinator or command sender is referenced.
final class MTPEventObserver {
    enum State: Equatable {
        case idle, observing, unavailable, stopped, terminated, failed
    }
    private final class Request {
        let buffer: NSMutableData
        init(size: Int) { buffer = NSMutableData(length: size)! }
        var lease: MTPAsyncResourceLease?
    }

    private let source: MTPEventSource
    private let lifetime: MTPTransportResourceLifetime
    private let enabled: Bool
    private let schedule: (@escaping () -> Void) -> Void
    private let clock: MTPDiagnosticClock
    private let record: (MTPEventRecord) -> Void
    private let status: (State) -> Void
    private var state: State = .idle
    private var request: Request?
    private var decoder = MTPEventDecoder()
    private var startTime: TimeInterval = 0
    private let stopLock = NSLock()
    private var stopRequested = false

    private var isStopRequested: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopRequested
    }

    init(source: MTPEventSource, lifetime: MTPTransportResourceLifetime, enabled: Bool,
         clock: MTPDiagnosticClock = MTPDiagnosticClock(),
         schedule: ((@escaping () -> Void) -> Void)? = nil,
         record: @escaping (MTPEventRecord) -> Void,
         status: @escaping (State) -> Void = { _ in }) {
        self.source = source
        self.lifetime = lifetime
        self.enabled = enabled
        self.clock = clock
        self.record = record
        self.status = status
        if let schedule {
            self.schedule = schedule
        } else {
            let queue = DispatchQueue(label: "MacdroidBridge.MTPEventObserver")
            self.schedule = { queue.async(execute: $0) }
        }
    }

    func start() {
        schedule { [self] in
            guard enabled, state == .idle, !isStopRequested else { return }
            guard source.hasEndpoint else { transition(.unavailable); return }
            startTime = clock.monotonicNow()
            transition(.observing)
            submit()
        }
    }

    func stop() { end(.stopped) }
    func terminate() { end(.terminated) }

    private func end(_ finalState: State) {
        stopLock.lock()
        let firstRequest = !stopRequested
        stopRequested = true
        stopLock.unlock()
        guard firstRequest else { return }
        schedule { [self] in
            guard state == .idle || state == .observing else { return }
            transition(finalState)
            // The pending lease protects both cancel and any inline callback.
            // Completion processing is queued behind this cancellation call.
            if request != nil { source.cancel() }
        }
    }

    private func transition(_ next: State) {
        state = next
        status(next)
    }

    private func submit() {
        // The locked stop check claims submission. No lock is held during source I/O.
        guard state == .observing, request == nil, !isStopRequested else { return }
        guard (MTPEventDecoder.maximumContainerBytes...4096).contains(source.transferBufferSize) else {
            transition(.failed); return
        }
        let pending = Request(size: source.transferBufferSize)
        do {
            pending.lease = try lifetime.acquireAsyncLease(retaining: [pending.buffer, source])
            request = pending
            try source.submit(into: pending.buffer) { [self, pending] result in
                // Keep source ownership, buffer and lease alive through processing.
                schedule { [self, pending] in complete(pending, result: result) }
            }
        } catch {
            request = nil
            pending.lease?.release()
            transition(.failed)
        }
    }

    private func complete(_ pending: Request, result: Result<Int, Error>) {
        guard request === pending else { return } // Duplicate/stale completion.
        defer {
            request = nil
            pending.lease?.release()
            // Queue rearm separately so an already queued stop wins.
            if state == .observing, !isStopRequested { schedule { [self] in submit() } }
        }
        guard state == .observing, !isStopRequested else { return }
        do {
            let count = try result.get()
            guard count > 0, count <= pending.buffer.length else {
                throw MTPEventDecoder.Failure.invalidLength
            }
            let events = try decoder.feed(Data(bytes: pending.buffer.bytes, count: count))
            let timestamp = clock.wallNow()
            let elapsed = clock.monotonicNow() - startTime
            for event in events { record(MTPEventRecord(event: event, timestamp: timestamp, elapsed: elapsed)) }
        } catch {
            transition(.failed)
        }
    }
}
