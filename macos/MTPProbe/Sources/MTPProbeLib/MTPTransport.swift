import Foundation
import IOKit
#if canImport(IOUSBHost)
import IOUSBHost
#endif

/// Abstraction over raw USB bulk endpoints, supporting dependency injection for tests
/// and deterministic disconnect/cancellation behaviors.
public protocol MTPTransport: AnyObject {
    /// Maximum packet size of the bulk OUT endpoint (typically 512 for USB 2.0 High-Speed).
    var bulkOutMaxPacketSize: Int { get }

    /// Send raw bytes to the bulk OUT endpoint.
    func write(data: Data, timeout: TimeInterval) throws

    /// Read raw bytes from the bulk IN endpoint up to `maxSize`.
    func read(maxSize: Int, timeout: TimeInterval) throws -> Data

    /// Abort any in-flight I/O requests on the endpoints asynchronously.
    func abort()

    /// Idempotently close and release underlying interface and pipe handles.
    func close()

    /// Determine if an error is a terminal transport failure (e.g. device unplugged, pipe destroyed).
    func isTerminalError(_ error: Error) -> Bool
}

/// Classifies transport errors to identify terminal disconnection events.
public struct MTPTransportErrorClassifier {
    // Standard IOKit / Mach / IOUSBHost 32-bit return codes (bit pattern)
    public static let codeIOReturnNoDevice: UInt32         = 0xe00002c0 // Device not present / removed
    public static let codeIOReturnNotResponding: UInt32     = 0xe00002ed // Device not responding
    public static let codeIOReturnAborted: UInt32           = 0xe00002eb // I/O aborted
    public static let codeIOReturnNotOpen: UInt32           = 0xe00002cd // Device/pipe not open
    public static let codeIOReturnOffline: UInt32           = 0xe00002d7 // Device offline
    public static let codeIOReturnNotAttached: UInt32       = 0xe00002d9 // Device not attached
    public static let codeIOReturnDeviceError: UInt32       = 0xe00002e9 // Device error
    public static let codeIOReturnNoPower: UInt32           = 0xe00002e3 // No power to device
    public static let codeIOUSBHostReturnPipeStalled: UInt32 = 0xe0005000 // IOUSBHost pipe stalled
    public static let codeIOUSBPipeStalled: UInt32          = 0xe000404f // IOUSB pipe stalled
    public static let codeIOUSBTransactionReturned: UInt32  = 0xe0004050 // IOUSB transaction returned
    public static let codeIOUSBTransactionTimeout: UInt32   = 0xe0004051 // IOUSB transaction timed out

    // Signed Int representations for convenient matching against NSError.code
    public static let kIOReturnNoDevice: Int = Int(Int32(bitPattern: codeIOReturnNoDevice))
    public static let kIOReturnNotResponding: Int = Int(Int32(bitPattern: codeIOReturnNotResponding))
    public static let kIOReturnAborted: Int = Int(Int32(bitPattern: codeIOReturnAborted))
    public static let kIOReturnNotOpen: Int = Int(Int32(bitPattern: codeIOReturnNotOpen))
    public static let kIOReturnOffline: Int = Int(Int32(bitPattern: codeIOReturnOffline))
    public static let kIOReturnNotAttached: Int = Int(Int32(bitPattern: codeIOReturnNotAttached))
    public static let kIOReturnDeviceError: Int = Int(Int32(bitPattern: codeIOReturnDeviceError))
    public static let kIOReturnNoPower: Int = Int(Int32(bitPattern: codeIOReturnNoPower))
    public static let kIOUSBHostReturnPipeStalled: Int = Int(Int32(bitPattern: codeIOUSBHostReturnPipeStalled))
    public static let kIOUSBPipeStalled: Int = Int(Int32(bitPattern: codeIOUSBPipeStalled))
    public static let kIOUSBTransactionReturned: Int = Int(Int32(bitPattern: codeIOUSBTransactionReturned))
    public static let kIOUSBTransactionTimeout: Int = Int(Int32(bitPattern: codeIOUSBTransactionTimeout))

    /// Returns true if the error indicates a physical disconnect, interface termination, or fatal stall.
    public static func isTerminal(_ error: Error) -> Bool {
        if let serializationError = error as? MTPSerializationError {
            switch serializationError {
            case .deviceDisconnected, .sessionPoisoned:
                return true
            default:
                break
            }
        }

        if let deviceError = error as? MTPDeviceError {
            switch deviceError {
            case .deviceDisconnected:
                return true
            default:
                break
            }
        }

        let nsError = error as NSError
        let uintCode = UInt32(bitPattern: Int32(truncatingIfNeeded: nsError.code))

        // Check exact 32-bit IOKit / IOUSBHost bit patterns
        if uintCode == codeIOReturnNoDevice ||
           uintCode == codeIOReturnNotResponding ||
           uintCode == codeIOReturnAborted ||
           uintCode == codeIOReturnNotOpen ||
           uintCode == codeIOReturnOffline ||
           uintCode == codeIOReturnNotAttached ||
           uintCode == codeIOReturnDeviceError ||
           uintCode == codeIOReturnNoPower ||
           uintCode == codeIOUSBHostReturnPipeStalled ||
           uintCode == codeIOUSBPipeStalled ||
           uintCode == codeIOUSBTransactionReturned {
            return true
        }

        // Check POSIX error domain
        if nsError.domain == NSPOSIXErrorDomain {
            let posixCode = nsError.code
            if posixCode == 19 /* ENODEV */ ||
               posixCode == 54 /* ECONNRESET */ ||
               posixCode == 6  /* ENXIO */ ||
               posixCode == 58 /* ESHUTDOWN */ ||
               posixCode == 89 /* ECANCELED */ ||
               posixCode == 32 /* EPIPE */ {
                return true
            }
        }

        // Secondary fallback: check localized string for non-standard error wrappers
        let desc = nsError.localizedDescription.lowercased()
        if desc.contains("no device") ||
           desc.contains("not responding") ||
           desc.contains("device detached") ||
           desc.contains("offline") ||
           desc.contains("pipe stalled") ||
           desc.contains("aborted") {
            return true
        }

        return false
    }
}

#if canImport(IOUSBHost)
/// Concrete MTPTransport backed by macOS IOUSBHost framework.
public final class IOUSBHostMTPTransport: MTPTransport {
    private let bulkInPipe: IOUSBHostPipe
    private let bulkOutPipe: IOUSBHostPipe
    public let bulkOutMaxPacketSize: Int

    private let lifetime: MTPTransportResourceLifetime

    public init(service: io_service_t) throws {
        // Log allowlisted interface properties
        var properties: Unmanaged<CFMutableDictionary>?
        let propertiesResult = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        if propertiesResult == kIOReturnSuccess,
           let registryProperties = properties?.takeRetainedValue() as? [String: Any] {
            let safeKeys = [
                "idVendor", "idProduct", "bInterfaceNumber", "bInterfaceClass",
                "bInterfaceSubClass", "bInterfaceProtocol", "USB Interface Number",
                "USB Interface Class", "USB Interface Subclass", "USB Interface Protocol"
            ]
            let summary = safeKeys.compactMap { key in
                registryProperties[key].map { "\(key)=\($0)" }
            }.joined(separator: ", ")
            print("MTP interface service properties: \(summary.isEmpty ? "(no allowlisted properties found)" : summary)")
        } else {
            print("MTP interface service properties unavailable (IORegistry result: \(propertiesResult))")
        }

        let intf: IOUSBHostInterface
        do {
            intf = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            let nsError = error as NSError
            print("IOUSBHostInterface initialization error: \(String(describing: error))")
            print("IOUSBHostInterface NSError domain: \(nsError.domain), code: \(nsError.code), description: \(nsError.localizedDescription)")
            throw MTPDeviceError.failedToCreateInterface
        }

        let confDesc = intf.configurationDescriptor
        let intfDesc = intf.interfaceDescriptor
        var epDesc = IOUSBGetNextEndpointDescriptor(confDesc, intfDesc, nil)

        var foundIn: IOUSBHostPipe?
        var foundOut: IOUSBHostPipe?
        var outPacketSize = 0

        while let desc = epDesc {
            let addr = IOUSBGetEndpointAddress(desc)
            let dir = IOUSBGetEndpointDirection(desc)
            let type = IOUSBGetEndpointType(desc)

            if type == 2 { // Bulk
                if dir == 1, foundIn == nil {
                    foundIn = try? intf.copyPipe(withAddress: Int(addr))
                } else if dir == 0, foundOut == nil {
                    foundOut = try? intf.copyPipe(withAddress: Int(addr))
                    outPacketSize = Int(UInt16(littleEndian: desc.pointee.wMaxPacketSize) & 0x07ff)
                }
            }

            epDesc = IOUSBGetNextEndpointDescriptor(
                confDesc,
                intfDesc,
                UnsafeRawPointer(desc).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
            )
        }

        guard let bulkIn = foundIn, let bulkOut = foundOut, outPacketSize > 0 else {
            throw MTPDeviceError.pipesNotFound
        }

        self.bulkInPipe = bulkIn
        self.bulkOutPipe = bulkOut
        self.bulkOutMaxPacketSize = outPacketSize
        self.lifetime = MTPTransportResourceLifetime(
            abort: {
                let requests = DispatchGroup()
                requests.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = try? bulkOut.__abort(with: .asynchronous)
                    requests.leave()
                }
                requests.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = try? bulkIn.__abort(with: .asynchronous)
                    requests.leave()
                }
                requests.wait()
            },
            destroy: { intf.destroy() }
        )
        print("Bulk OUT endpoint packet size: \(outPacketSize)")
        print("Successfully created IOUSBHostInterface and located bulk pipes.")
    }

    public func write(data: Data, timeout: TimeInterval) throws {
        try lifetime.performIO {
            let mutableData: NSMutableData? = data.isEmpty ? nil : NSMutableData(data: data)
            var transferred: Int = 0

            do {
                try bulkOutPipe.__sendIORequest(
                    with: mutableData,
                    bytesTransferred: &transferred,
                    completionTimeout: timeout
                )
                guard transferred == data.count else {
                    throw MTPDeviceError.sendCommandFailed(
                        "Short USB write: expected \(data.count) bytes, transferred \(transferred)"
                    )
                }
            } catch {
                if isTerminalError(error) {
                    throw MTPDeviceError.deviceDisconnected(error.localizedDescription)
                }
                throw MTPDeviceError.sendCommandFailed(error.localizedDescription)
            }
        }
    }

    public func read(maxSize: Int, timeout: TimeInterval) throws -> Data {
        try lifetime.performIO {
            let receiveBuffer = NSMutableData(length: maxSize)!
            var receivedBytes: Int = 0

            do {
                try bulkInPipe.__sendIORequest(
                    with: receiveBuffer,
                    bytesTransferred: &receivedBytes,
                    completionTimeout: timeout
                )
            } catch {
                if isTerminalError(error) {
                    throw MTPDeviceError.deviceDisconnected(error.localizedDescription)
                }
                throw MTPDeviceError.receiveDataFailed(error.localizedDescription)
            }

            return Data(bytes: receiveBuffer.bytes, count: receivedBytes)
        }
    }

    public func abort() {
        lifetime.requestAbort()
    }

    public func close() {
        _ = lifetime.close()
    }

    public func isTerminalError(_ error: Error) -> Bool {
        return MTPTransportErrorClassifier.isTerminal(error)
    }
}
#endif
