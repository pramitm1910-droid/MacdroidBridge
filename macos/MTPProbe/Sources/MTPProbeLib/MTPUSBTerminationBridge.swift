import Foundation
import IOKit
#if canImport(IOUSBHost)
import IOUSBHost
#endif

/// Construct BEFORE interface initialization and pass interestHandler to its init.
/// A termination arriving before bind is remembered. No registration happens here.
/// Delivery never waits on either the IOKit interest queue or I/O completion queue.
final class MTPUSBTerminationBridge {
    // IOMessage.h: iokit_common_msg(0x010); the C macro is not imported by Swift.
    static let serviceIsTerminated: UInt32 = 0xe0000010
    private let lock = NSLock()
    private var terminated = false
    private var bound = false
    private var action: (() -> Void)?
    private let scheduleInvalidation: (@escaping () -> Void) -> Void

    init(scheduleInvalidation: ((@escaping () -> Void) -> Void)? = nil) {
        let queue = DispatchQueue(label: "MacdroidBridge.TerminationInvalidation")
        self.scheduleInvalidation = scheduleInvalidation ?? { queue.async(execute: $0) }
    }

    var isTerminated: Bool {
        lock.lock(); defer { lock.unlock() }; return terminated
    }

    /// Bind once, before starting observation. stopAdmission must be nonblocking
    /// (only latch/queue cancellation). invalidate may block, so is always queued.
    func bind(stopAdmission: @escaping () -> Void, invalidate: @escaping () -> Void) {
        let delivery = { [scheduleInvalidation] in
            stopAdmission()
            scheduleInvalidation(invalidate)
        }
        lock.lock()
        guard !bound else { lock.unlock(); return }
        bound = true
        let deliverNow = terminated
        if !deliverNow { action = delivery }
        lock.unlock()
        if deliverNow { delivery() }
    }

    func bind(source: MTPInterruptEventSource, observer: MTPEventObserver, device: MTPDevice) {
        bind(stopAdmission: { [weak source, weak observer] in
            source?.cancel()
            observer?.terminate()
        }, invalidate: { [weak device] in
            device?.disconnect(reason: "USB interface terminated")
        })
    }

    func receive(message: UInt32) {
        guard message == Self.serviceIsTerminated else { return }
        lock.lock()
        guard !terminated else { lock.unlock(); return }
        terminated = true
        let delivery = action
        action = nil
        lock.unlock()
        delivery?()
    }

#if canImport(IOUSBHost)
    var interestHandler: IOUSBHostInterestHandler {
        { [self] _, message, _ in receive(message: message) }
    }
#endif
}
