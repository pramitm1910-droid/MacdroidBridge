import Foundation
import IOKit
import IOUSBHost

public enum USBDiscoveryError: Error {
    case noDevicesFound
    case iterationFailed
}

public struct USBDeviceDiscovery {
    
    /// Finds the first connected MTP/PTP USB interface.
    /// MTP devices advertise themselves with Interface Class 6 (Image), Subclass 1, Protocol 1.
    public static func findFirstMTPInterface() throws -> io_service_t {
        // Create matching dictionary for an MTP interface
        // Interface Class 0x06 (Image), Subclass 0x01 (Still Image Capture), Protocol 0x01 (PTP/MTP)
        let matchDict = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: nil,
            productID: nil,
            bcdDevice: nil,
            interfaceNumber: nil,
            configurationValue: nil,
            interfaceClass: NSNumber(value: 0x06),
            interfaceSubclass: NSNumber(value: 0x01),
            interfaceProtocol: NSNumber(value: 0x01),
            speed: nil,
            productIDArray: nil
        )
        
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matchDict.takeRetainedValue(),
            &iterator
        )
        
        guard result == kIOReturnSuccess, iterator != 0 else {
            throw USBDiscoveryError.iterationFailed
        }
        
        defer { IOObjectRelease(iterator) }
        
        // Return the first matching interface
        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            throw USBDiscoveryError.noDevicesFound
        }
        
        // We're responsible for releasing the service when we're done with it,
        // but since we're returning it to the caller, the caller assumes ownership.
        return service
    }
}
