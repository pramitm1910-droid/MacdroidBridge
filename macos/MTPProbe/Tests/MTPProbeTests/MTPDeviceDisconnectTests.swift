import Foundation
import XCTest
@testable import MTPProbeLib

final class MTPDeviceDisconnectTests: XCTestCase {

    // Helper to generate a minimal MTP response container packet
    private func makeResponsePacket(code: UInt16 = MTPResponseCode.ok.rawValue, transactionID: UInt32, parameters: [UInt32] = []) -> Data {
        let length = UInt32(12 + parameters.count * 4)
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: MTPContainerType.response.rawValue.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: code.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: transactionID.littleEndian) { Array($0) })
        for p in parameters {
            data.append(contentsOf: withUnsafeBytes(of: p.littleEndian) { Array($0) })
        }
        return data
    }

    // Helper to generate a minimal MTP data container packet
    private func makeDataPacket(code: UInt16, transactionID: UInt32, payload: Data) -> Data {
        let length = UInt32(12 + payload.count)
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: MTPContainerType.data.rawValue.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: code.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: transactionID.littleEndian) { Array($0) })
        data.append(payload)
        return data
    }

    private final class MockMTPTransport: MTPTransport {
        var bulkOutMaxPacketSize: Int = 512
        var writeHandler: ((Data, TimeInterval) throws -> Void)?
        var readHandler: ((Int, TimeInterval) throws -> Data)?
        var isTerminalErrorHandler: ((Error) -> Bool)?
        var abortHandler: (() -> Void)?
        var closeHandler: (() -> Void)?

        private let lock = NSLock()
        var abortCallCount = 0
        var closeCallCount = 0

        func write(data: Data, timeout: TimeInterval) throws {
            if let handler = writeHandler {
                try handler(data, timeout)
            }
        }

        func read(maxSize: Int, timeout: TimeInterval) throws -> Data {
            if let handler = readHandler {
                return try handler(maxSize, timeout)
            }
            return Data()
        }

        func abort() {
            lock.lock()
            abortCallCount += 1
            let handler = abortHandler
            lock.unlock()
            handler?()
        }

        func close() {
            lock.lock()
            closeCallCount += 1
            let handler = closeHandler
            lock.unlock()
            handler?()
        }

        func isTerminalError(_ error: Error) -> Bool {
            if let handler = isTerminalErrorHandler {
                return handler(error)
            }
            return MTPTransportErrorClassifier.isTerminal(error)
        }
    }

    private func openSessionOnMock(device: MTPDevice, transport: MockMTPTransport) throws {
        transport.writeHandler = { _, _ in }
        transport.readHandler = { _, _ in
            self.makeResponsePacket(transactionID: MTPTransactionIDAllocator.openSessionTransactionID)
        }
        try device.openSession()
    }

    // MARK: - Test Cases

    func testDisconnectDuringActiveOperation() throws {
        let transport = MockMTPTransport()
        let device = MTPDevice(transport: transport)
        try openSessionOnMock(device: device, transport: transport)

        // Simulate terminal disconnection during write
        transport.writeHandler = { _, _ in
            throw NSError(
                domain: "IOKit",
                code: MTPTransportErrorClassifier.kIOReturnNoDevice,
                userInfo: [NSLocalizedDescriptionKey: "Device disconnected / no device"]
            )
        }

        XCTAssertThrowsError(try device.getStorageIDs()) { error in
            guard case MTPDeviceError.deviceDisconnected = error else {
                return XCTFail("Expected deviceDisconnected error, got \(error)")
            }
        }

        XCTAssertTrue(device.isDisconnected)
        XCTAssertEqual(transport.closeCallCount, 1)

        // Subsequent operation must fail immediately without touching transport
        var transportInvoked = false
        transport.writeHandler = { _, _ in transportInvoked = true }
        XCTAssertThrowsError(try device.getStorageIDs()) { error in
            guard case MTPSerializationError.deviceDisconnected = error else {
                return XCTFail("Expected deviceDisconnected serialization error, got \(error)")
            }
        }
        XCTAssertFalse(transportInvoked, "Failed session must reject requests without hitting transport")
    }

    func testDisconnectWhileRequestsAreQueued() throws {
        let transport = MockMTPTransport()
        let device = MTPDevice(transport: transport)
        try openSessionOnMock(device: device, transport: transport)

        let holdGroup = DispatchGroup()
        let waitGroup = DispatchGroup()
        let holdStarted = XCTestExpectation(description: "hold started")
        let canReleaseHold = XCTestExpectation(description: "can release hold")

        // Hold active operation in Thread 1
        transport.writeHandler = { _, _ in
            holdStarted.fulfill()
            self.wait(for: [canReleaseHold], timeout: 2.0)
            throw NSError(
                domain: "IOKit",
                code: MTPTransportErrorClassifier.kIOReturnAborted,
                userInfo: [NSLocalizedDescriptionKey: "I/O aborted"]
            )
        }
        transport.abortHandler = {
            canReleaseHold.fulfill()
        }
        transport.readHandler = { _, _ in
            self.makeResponsePacket(transactionID: 1)
        }

        holdGroup.enter()
        DispatchQueue.global().async {
            _ = try? device.getDeviceInfo()
            holdGroup.leave()
        }

        wait(for: [holdStarted], timeout: 1.0)

        // Queue Thread 2 and Thread 3
        var queuedErrors: [Error] = []
        let lock = NSLock()

        for _ in 1...2 {
            waitGroup.enter()
            DispatchQueue.global().async {
                do {
                    _ = try device.getStorageIDs()
                } catch {
                    lock.lock()
                    queuedErrors.append(error)
                    lock.unlock()
                }
                waitGroup.leave()
            }
        }

        Thread.sleep(forTimeInterval: 0.05)

        // Disconnect the device while operations are queued (triggers transport.abort)
        device.disconnect(reason: "USB cable detached")

        holdGroup.wait()
        waitGroup.wait()

        XCTAssertEqual(queuedErrors.count, 2)
        for err in queuedErrors {
            guard case MTPSerializationError.deviceDisconnected(let reason) = err else {
                return XCTFail("Expected deviceDisconnected error, got \(err)")
            }
            XCTAssertTrue(reason.contains("USB cable detached"))
        }
        XCTAssertTrue(device.isDisconnected)
    }

    func testRepeatedShutdownCallsAreIdempotent() {
        let transport = MockMTPTransport()
        let device = MTPDevice(transport: transport)

        XCTAssertFalse(device.isDisconnected)
        device.shutdown()
        XCTAssertTrue(device.isDisconnected)
        XCTAssertEqual(transport.closeCallCount, 1)

        // Repeated calls must be safe and exactly-once
        device.shutdown()
        device.disconnect(reason: "Second disconnect")
        device.shutdown()
        XCTAssertEqual(transport.closeCallCount, 1)
    }

    func testTerminalUSBErrorPropagation() throws {
        let transport = MockMTPTransport()
        let device = MTPDevice(transport: transport)
        try openSessionOnMock(device: device, transport: transport)

        // Test kIOReturnNotResponding
        transport.writeHandler = { _, _ in
            throw NSError(
                domain: "IOKit",
                code: MTPTransportErrorClassifier.kIOReturnNotResponding,
                userInfo: [NSLocalizedDescriptionKey: "Device not responding"]
            )
        }

        XCTAssertThrowsError(try device.getDeviceInfo()) { error in
            guard case MTPDeviceError.deviceDisconnected = error else {
                return XCTFail("Expected deviceDisconnected error, got \(error)")
            }
        }
        XCTAssertTrue(device.isDisconnected)
        XCTAssertEqual(transport.closeCallCount, 1)
    }

    func testCleanupOwnershipAndExactlyOnceResourceRelease() {
        let transport = MockMTPTransport()
        do {
            let device = MTPDevice(transport: transport)
            XCTAssertFalse(device.isDisconnected)
            // Allow device to exit scope without calling shutdown
        }
        // deinit must trigger close exactly once
        XCTAssertEqual(transport.closeCallCount, 1)

        // Now test when shutdown was already called before deinit
        let transport2 = MockMTPTransport()
        do {
            let device2 = MTPDevice(transport: transport2)
            device2.shutdown()
            XCTAssertEqual(transport2.closeCallCount, 1)
        }
        // Should still be exactly 1 after deinit
        XCTAssertEqual(transport2.closeCallCount, 1)
    }

    func testCancellationDoesNotPoisonSessionWhereasDisconnectDoes() throws {
        let coordinator = MTPSessionCoordinator()
        try coordinator.openSession { _ in 1 }

        let holdGroup = DispatchGroup()
        let waitGroup = DispatchGroup()
        let holdStarted = XCTestExpectation(description: "hold started")
        let canReleaseHold = XCTestExpectation(description: "can release hold")

        holdGroup.enter()
        DispatchQueue.global().async {
            _ = try? coordinator.perform { scope in
                holdStarted.fulfill()
                self.wait(for: [canReleaseHold], timeout: 2.0)
                let tx = try scope.allocateTransactionID()
                try scope.completeTransaction(tx)
            }
            holdGroup.leave()
        }

        wait(for: [holdStarted], timeout: 1.0)

        // Queue an operation
        var waiterError: Error?
        waitGroup.enter()
        DispatchQueue.global().async {
            do {
                _ = try coordinator.perform { _ in }
            } catch {
                waiterError = error
            }
            waitGroup.leave()
        }

        Thread.sleep(forTimeInterval: 0.03)
        XCTAssertEqual(coordinator.queuedWaiterCount, 1)

        // Cancel pending waiters (cooperative queued-cancellation)
        coordinator.cancelPendingWaiters()

        canReleaseHold.fulfill()
        holdGroup.wait()
        waitGroup.wait()

        // Waiter received .cancelled
        XCTAssertEqual(waiterError as? MTPSerializationError, .cancelled)

        // Session must STILL be active and not failed!
        XCTAssertFalse(coordinator.isFailed)
        XCTAssertEqual(coordinator.sessionState, .active(sessionID: 1))

        // Subsequent operation succeeds
        var success = false
        try coordinator.perform { scope in
            let tx = try scope.allocateTransactionID()
            try scope.completeTransaction(tx)
            success = true
        }
        XCTAssertTrue(success)

        // Now disconnect: session is permanently failed
        coordinator.disconnect(reason: "Unplugged")
        XCTAssertTrue(coordinator.isFailed)
        XCTAssertThrowsError(try coordinator.perform { _ in }) { error in
            guard case MTPSerializationError.deviceDisconnected = error else {
                return XCTFail("Expected deviceDisconnected error, got \(error)")
            }
        }
    }

    func testNoDeadlocksDuringConcurrentShutdown() {
        let transport = MockMTPTransport()
        let device = MTPDevice(transport: transport)

        let group = DispatchGroup()
        for _ in 1...10 {
            group.enter()
            DispatchQueue.global().async {
                device.shutdown()
                group.leave()
            }
        }

        let completed = group.wait(timeout: .now() + 2.0)
        XCTAssertEqual(completed, .success, "Concurrent shutdown calls must not deadlock")
        XCTAssertTrue(device.isDisconnected)
        XCTAssertEqual(transport.closeCallCount, 1)
    }

    func testActiveMockedReadBlockedWhileShutdownBegins() throws {
        let transport = MockMTPTransport()
        let device = MTPDevice(transport: transport)
        try openSessionOnMock(device: device, transport: transport)

        let readStarted = XCTestExpectation(description: "read started")
        let readExited = XCTestExpectation(description: "read exited")
        let abortCalled = XCTestExpectation(description: "abort called")
        let semaphore = DispatchSemaphore(value: 0)

        var readIsActive = false
        var closeExecutedWhileReadActive = false
        var operationError: Error?

        transport.readHandler = { _, _ in
            readIsActive = true
            readStarted.fulfill()
            // Block in simulated synchronous hardware read until abort() is called
            semaphore.wait()
            readIsActive = false
            readExited.fulfill()
            throw NSError(
                domain: "IOKit",
                code: MTPTransportErrorClassifier.kIOReturnAborted,
                userInfo: [NSLocalizedDescriptionKey: "I/O aborted"]
            )
        }

        transport.abortHandler = {
            abortCalled.fulfill()
            semaphore.signal() // Unblock the blocked read upon abort
        }

        transport.closeHandler = {
            if readIsActive {
                closeExecutedWhileReadActive = true
            }
        }

        // Thread 1: Start active operation that enters blocking read
        let opGroup = DispatchGroup()
        opGroup.enter()
        DispatchQueue.global().async {
            do {
                _ = try device.getDeviceInfo()
            } catch {
                operationError = error
            }
            opGroup.leave()
        }

        wait(for: [readStarted], timeout: 1.0)
        XCTAssertTrue(readIsActive)

        // Thread 2: Call shutdown while Thread 1 is blocked in read
        device.shutdown()

        wait(for: [abortCalled, readExited], timeout: 2.0)
        opGroup.wait()

        XCTAssertFalse(closeExecutedWhileReadActive, "Transport close must not destroy resources while active read is running")
        XCTAssertTrue(device.isDisconnected)
        guard let devErr = operationError as? MTPDeviceError, case .deviceDisconnected = devErr else {
            return XCTFail("Expected deviceDisconnected error, got \(String(describing: operationError))")
        }
    }

    func testShutdownInvokedFromWithinActiveOperationDoesNotSelfDeadlock() throws {
        let transport = MockMTPTransport()
        let device = MTPDevice(transport: transport)
        try openSessionOnMock(device: device, transport: transport)

        var shutdownCompleted = false
        transport.writeHandler = { _, _ in
            // Execute shutdown directly from within the executing thread
            device.shutdown()
            shutdownCompleted = true
        }

        _ = try? device.getDeviceInfo()

        XCTAssertTrue(shutdownCompleted, "Shutdown within active operation must return without self-deadlock")
        XCTAssertTrue(device.isDisconnected)
    }

    func testTerminalIOKitErrorClassificationByDomainAndCode() {
        let domains = ["IOUSBHostErrorDomain", "IOKitErrorDomain", "IOKit", "NSMachErrorDomain", "CustomDomain"]
        let terminalCodes: [UInt32] = [
            0xe00002c0, // kIOReturnNoDevice
            0xe00002ed, // kIOReturnNotResponding
            0xe00002eb, // kIOReturnAborted
            0xe00002cd, // kIOReturnNotOpen
            0xe00002d7, // kIOReturnOffline
            0xe00002d9, // kIOReturnNotAttached
            0xe00002e9, // kIOReturnDeviceError
            0xe00002e3, // kIOReturnNoPower
            0xe0005000, // kUSBHostReturnPipeStalled
            0xe000404f, // kIOUSBPipeStalled
            0xe0004050, // kIOUSBTransactionReturned
        ]

        for domain in domains {
            for uintCode in terminalCodes {
                let code = Int(Int32(bitPattern: uintCode))
                let error = NSError(domain: domain, code: code, userInfo: nil)
                XCTAssertTrue(
                    MTPTransportErrorClassifier.isTerminal(error),
                    "Expected code 0x\(String(uintCode, radix: 16)) in domain \(domain) to be classified as terminal"
                )
            }
        }

        // Test POSIX terminal errors
        let posixTerminalCodes = [19 /* ENODEV */, 54 /* ECONNRESET */, 6 /* ENXIO */, 58 /* ESHUTDOWN */, 89 /* ECANCELED */, 32 /* EPIPE */]
        for code in posixTerminalCodes {
            let error = NSError(domain: NSPOSIXErrorDomain, code: code, userInfo: nil)
            XCTAssertTrue(MTPTransportErrorClassifier.isTerminal(error))
        }

        // Test non-terminal errors
        let nonTerminalErrors = [
            NSError(domain: "IOKit", code: 0, userInfo: nil), // kIOReturnSuccess
            NSError(domain: "IOKit", code: Int(Int32(bitPattern: 0xe00002c2)), userInfo: nil), // kIOReturnBadArgument
            NSError(domain: NSPOSIXErrorDomain, code: 1 /* EPERM */, userInfo: nil),
            NSError(domain: "GenericDomain", code: 1234, userInfo: nil),
        ]
        for err in nonTerminalErrors {
            XCTAssertFalse(MTPTransportErrorClassifier.isTerminal(err), "Error \(err) should not be classified as terminal")
        }
    }
}
