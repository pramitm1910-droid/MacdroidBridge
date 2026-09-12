import Foundation
import IOKit

print("AndroidMacBridge MTP Probe")
print("==========================\n")

print("Searching for MTP USB devices...")

do {
    let service = try USBDeviceDiscovery.findFirstMTPInterface()
    
    print("\nMTP interface detected")
    print("Service: \(service)")
    
    // Get some properties from the service to identify the device
    var props: Unmanaged<CFMutableDictionary>?
    let result = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
    
    if result == kIOReturnSuccess, let propertiesDict = props?.takeRetainedValue() as? [String: Any] {
        if let vendorID = propertiesDict["idVendor"] as? Int {
            print(String(format: "VID: 0x%04X", vendorID))
        }
        if let productID = propertiesDict["idProduct"] as? Int {
            print(String(format: "PID: 0x%04X", productID))
        }
    }
    
    print("\nTerminating conflicting daemons...")
    AndroidDaemonKiller.terminateConflictingDaemons()
    
    // Slight pause to ensure daemon is killed and releases interface
    Thread.sleep(forTimeInterval: 1.0)
    
    print("\nEstablishing MTP session...")
    let device = try MTPDevice(service: service)
    try device.openSession()
    
    print("\nRetrieving basic device information...")
    let deviceInfo = try device.getDeviceInfo()
    print("Manufacturer: \(deviceInfo.manufacturer)")
    print("Model: \(deviceInfo.model)")
    print("Serial Number: \(deviceInfo.serialNumber)")
    print("Device Version: \(deviceInfo.deviceVersion)")
    
    print("\nEnumerating storage volumes...")
    let storageIDs = try device.getStorageIDs()
    if storageIDs.isEmpty {
        print("No storage volumes found.")
    }
    
    for id in storageIDs {
        let storageInfo = try device.getStorageInfo(storageID: id)
        print("\n* \(storageInfo.displayName)")
        print("  ID: 0x\(String(id, radix: 16, uppercase: true))")
        print("  Capacity: \(storageInfo.capacityString)")
        print("  Free Space: \(storageInfo.freeString)")
        print("  Access: \(storageInfo.accessCapability == 0 ? "Read/Write" : "Read Only")")
        
        print("\n  Root Directory:")
        let objectHandles = try device.getObjectHandles(storageID: id)
        if objectHandles.isEmpty {
            print("    (Empty)")
        } else {
            // Print up to 10 objects to avoid overwhelming the console
            for handle in objectHandles.prefix(10) {
                let objectInfo = try device.getObjectInfo(objectHandle: handle)
                let type = objectInfo.isDirectory ? "[DIR]" : "[FILE]"
                print("    * \(type) \(objectInfo.filename)")
            }
            if objectHandles.count > 10 {
                print("    ... and \(objectHandles.count - 10) more items")
            }
        }
    }
    
    // Clean up
    IOObjectRelease(service)
    
    print("\nMTP Probe complete.")
    
} catch USBDiscoveryError.noDevicesFound {
    print("No MTP USB devices found. Please ensure an Android device is connected and unlocked in MTP (File Transfer) mode.")
} catch {
    print("Error during USB discovery: \(error)")
}
