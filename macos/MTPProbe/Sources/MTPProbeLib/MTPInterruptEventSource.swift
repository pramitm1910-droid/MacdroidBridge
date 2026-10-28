import Foundation
import IOKit
#if canImport(IOUSBHost)
import IOUSBHost
#endif

enum MTPInterruptError: Error { case invalidEndpoint, busy, stopped, invalidBuffer }

/// Descriptor-only discovery. No pipe acquisition or USB requests. Reject ambiguous
/// endpoints and unsupported (>4 KiB/service interval) configurations conservatively.
struct MTPInterruptEndpoint: Equatable {
    let address: UInt8
    let bufferSize: Int

    static func discover(configuration: Data, interface: UInt8, alternate: UInt8) throws -> Self? {
        let bytes = Array(configuration)
        var offset = 0
        var selected = false
        var candidates: [(address: UInt8, packet: Int, capacity: Int)] = []
        var lastCandidate: Int?
        while offset < bytes.count {
            guard offset + 2 <= bytes.count else { throw MTPInterruptError.invalidEndpoint }
            let size = Int(bytes[offset])
            let type = bytes[offset + 1]
            guard size >= 2, size <= bytes.count - offset else { throw MTPInterruptError.invalidEndpoint }
            let d = Array(bytes[offset..<(offset + size)])
            if type == 4 {
                guard size >= 9 else { throw MTPInterruptError.invalidEndpoint }
                selected = d[2] == interface && d[3] == alternate
                lastCandidate = nil
            } else if type == 5 {
                lastCandidate = nil
                guard size >= 7 else { throw MTPInterruptError.invalidEndpoint }
                if selected, d[3] & 3 == 3, d[2] & 0x80 != 0 {
                    let raw = Int(d[4]) | Int(d[5]) << 8
                    let packet = raw & 0x7ff
                    let mult = (raw >> 11) & 3
                    guard d[2] & 0x70 == 0, d[2] & 15 != 0, d[3] & 0xfc == 0,
                          packet > 0, packet <= 1024, raw & 0xe000 == 0, mult < 3,
                          d[6] > 0 else { throw MTPInterruptError.invalidEndpoint }
                    candidates.append((d[2], packet, packet * (mult + 1)))
                    lastCandidate = candidates.count - 1
                }
            } else if type == 48, let index = lastCandidate {
                guard size == 6, d[2] <= 15, d[3] == 0 else { throw MTPInterruptError.invalidEndpoint }
                let capacity = Int(d[4]) | Int(d[5]) << 8
                guard capacity > 0, capacity <= candidates[index].packet * (Int(d[2]) + 1) else {
                    throw MTPInterruptError.invalidEndpoint
                }
                candidates[index].capacity = capacity
                lastCandidate = nil
            } else {
                lastCandidate = nil
            }
            offset += size
        }
        guard candidates.count <= 1 else { throw MTPInterruptError.invalidEndpoint }
        guard let endpoint = candidates.first else { return nil }
        let capacity = ((max(24, endpoint.capacity) + endpoint.packet - 1) / endpoint.packet) * endpoint.packet
        guard capacity <= 4096 else { throw MTPInterruptError.invalidEndpoint }
        return Self(address: endpoint.address, bufferSize: capacity)
    }
}

/// Injectable USB boundary. Throw means submission was rejected (no accepted I/O).
/// Implementations must not access the buffer after delivering completion.
protocol MTPInterruptPipe: AnyObject {
    func enqueue(_ buffer: NSMutableData, completion: @escaping (Result<Int, Error>) -> Void) throws
    func abort() throws
}

/// Inactive until explicitly submitted by a diagnostic observer. The serial worker
/// orders submission, completion and abort; the lock only protects admission.
/// The observer holds a separate lease through decoding/record delivery.
final class MTPInterruptEventSource: MTPEventSource {
    let hasEndpoint: Bool
    let transferBufferSize: Int
    private let pipe: MTPInterruptPipe?
    private let lifetime: MTPTransportResourceLifetime
    private let schedule: (@escaping () -> Void) -> Void
    private let reportAbortError: (Error) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var pending: Request?

    private final class Request {
        let buffer: NSMutableData
        let completion: (Result<Int, Error>) -> Void
        var lease: MTPAsyncResourceLease?
        init(_ buffer: NSMutableData, _ completion: @escaping (Result<Int, Error>) -> Void) {
            self.buffer = buffer; self.completion = completion
        }
    }

    /// schedule must enqueue serially, never inline; injectable for deterministic tests.
    init(pipe: MTPInterruptPipe?, endpoint: MTPInterruptEndpoint?, lifetime: MTPTransportResourceLifetime,
         schedule: ((@escaping () -> Void) -> Void)? = nil,
         reportAbortError: @escaping (Error) -> Void = { _ in }) {
        self.pipe = pipe
        hasEndpoint = pipe != nil && endpoint != nil
        transferBufferSize = endpoint?.bufferSize ?? 24
        self.lifetime = lifetime
        self.reportAbortError = reportAbortError
        let queue = DispatchQueue(label: "MacdroidBridge.InterruptSubmission")
        self.schedule = schedule ?? { queue.async(execute: $0) }
    }

    func submit(into buffer: NSMutableData, completion: @escaping (Result<Int, Error>) -> Void) throws {
        guard hasEndpoint else { throw MTPInterruptError.invalidEndpoint }
        guard (24...4096).contains(transferBufferSize), buffer.length == transferBufferSize else {
            throw MTPInterruptError.invalidBuffer
        }
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw MTPInterruptError.stopped }
        guard pending == nil else { throw MTPInterruptError.busy }
        let request = Request(buffer, completion)
        // Explicit gate ownership protects even a driver that loses its callback.
        request.lease = try lifetime.acquireAsyncLease(retaining: [request, self])
        pending = request
        schedule { [self, request] in
            lock.lock(); let shouldSubmit = !stopped; lock.unlock()
            guard shouldSubmit, lifetime.cleanupState == .open else { finish(request, .failure(MTPInterruptError.stopped)); return }
            do {
                try pipe!.enqueue(request.buffer) { [self, request] result in
                    schedule { [self, request] in finish(request, result) }
                }
            } catch {
                finish(request, .failure(error))
            }
        }
    }

    func cancel() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        schedule { [self] in
            // Serial completion cannot release this request while abort is executing.
            lock.lock(); let request = pending; lock.unlock()
            guard request != nil else { return }
            do { try pipe?.abort() } catch { reportAbortError(error) }
            // Never synthesize completion or release a lease on abort, even on error.
        }
    }

    private func finish(_ request: Request, _ result: Result<Int, Error>) {
        lock.lock()
        guard pending === request else { lock.unlock(); return }
        pending = nil
        lock.unlock()
        defer { request.lease?.release() }
        if case .success(let count) = result, count < 0 || count > request.buffer.length {
            request.completion(.failure(MTPInterruptError.invalidBuffer))
        } else {
            request.completion(result)
        }
    }
}

#if canImport(IOUSBHost)
/// No caller in normal transport/CLI: Stage 2B must supply the SAME interface gate,
/// wire close to cancel, and connect termination before activating this factory.
extension MTPInterruptEventSource {
    static func make(interface: IOUSBHostInterface, lifetime: MTPTransportResourceLifetime,
                     reportAbortError: @escaping (Error) -> Void) throws -> MTPInterruptEventSource {
        try lifetime.performIO {
            let configuration = interface.configurationDescriptor
            let descriptor = interface.interfaceDescriptor.pointee
            let length = Int(UInt16(littleEndian: configuration.pointee.wTotalLength))
            let endpoint = try MTPInterruptEndpoint.discover(
                configuration: Data(bytes: configuration, count: length),
                interface: descriptor.bInterfaceNumber, alternate: descriptor.bAlternateSetting)
            let pipe = try endpoint.map { try interface.copyPipe(withAddress: Int($0.address)) }
            return MTPInterruptEventSource(pipe: pipe.map(HostInterruptPipe.init), endpoint: endpoint,
                                           lifetime: lifetime, reportAbortError: reportAbortError)
        }
    }
}

private final class HostInterruptPipe: MTPInterruptPipe {
    let pipe: IOUSBHostPipe
    init(_ pipe: IOUSBHostPipe) { self.pipe = pipe }
    func enqueue(_ buffer: NSMutableData, completion: @escaping (Result<Int, Error>) -> Void) throws {
        try pipe.enqueueIORequest(with: buffer, completionTimeout: 0) { status, count in
            if status == kIOReturnSuccess { completion(.success(count)) }
            else { completion(.failure(NSError(domain: NSMachErrorDomain, code: Int(status)))) }
        }
    }
    func abort() throws { try pipe.__abort(with: .asynchronous) }
}
#endif
