import Foundation
import IOKit
import IOUSBHost
import MTPProbeLib

public enum USBDiscoveryError: Error {
    case noDevicesFound
}

public struct USBDeviceDiscovery {
    public struct Target {
        fileprivate let service: io_service_t
        fileprivate let identity: USBTargetSelection.Selection
        public var interfaceService: io_service_t { service }
    }

    /// Only registry properties are inspected. No IOUSBHostInterface is opened here.
    private static func services<T>(_ matching: CFDictionary, query: String,
                                    body: ([io_service_t]) throws -> T) throws -> T {
        try USBDiscoveryDiagnostics.withServices(query: query, acquire: {
            var iterator: io_iterator_t = 0
            let code = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
            return (code, iterator)
        }, next: { IOIteratorNext($0) }, isValid: { IOIteratorIsValid($0) != 0 },
           release: { _ = IOObjectRelease($0) }, body: body)
    }
    private static func properties(_ service: io_service_t) throws -> [String: Any] {
        var value: Unmanaged<CFMutableDictionary>?
        let code = IORegistryEntryCreateCFProperties(service, &value, kCFAllocatorDefault, 0)
        let object = value?.takeRetainedValue()
        try USBDiscoveryDiagnostics.require(code == kIOReturnSuccess, stage: .descriptorAccess,
            operation: "IORegistryEntryCreateCFProperties", code: code, detail: "property access failed")
        guard let properties = object as? [String: Any] else {
            throw USBDiscoveryFailure(.descriptorAccess, "IORegistryEntryCreateCFProperties", code: code,
                                      detail: "missing or malformed property dictionary")
        }
        return properties
    }
    private static func identity(_ service: io_service_t) throws -> UInt64 {
        var id: UInt64 = 0
        let code = IORegistryEntryGetRegistryEntryID(service, &id)
        try USBDiscoveryDiagnostics.require(code == kIOReturnSuccess && id != 0, stage: .descriptorAccess,
            operation: "IORegistryEntryGetRegistryEntryID", code: code,
            detail: code == kIOReturnSuccess ? "missing registry identity" : "registry identity access failed")
        return id
    }
    private static func parentDeviceID(_ service: io_service_t) throws -> UInt64 {
        var parent: io_registry_entry_t = 0
        let code = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)
        defer { if parent != 0 { IOObjectRelease(parent) } }
        try USBDiscoveryDiagnostics.require(code == kIOReturnSuccess && parent != 0, stage: .descriptorAccess,
            operation: "IORegistryEntryGetParentEntry", code: code, detail: "device parent unavailable")
        try USBDiscoveryDiagnostics.require(IOObjectConformsTo(parent, "IOUSBHostDevice") != 0,
            stage: .interfaceValidation, operation: "IOObjectConformsTo", detail: "unexpected parent topology")
        return try identity(parent)
    }
    private static func selected<T>(expected: USBTargetSelection.Selection? = nil,
                                    body: (io_service_t, USBTargetSelection.Selection) throws -> T) throws -> T {
        let deviceMatch = try USBMatchingQueries.devices()
        return try services(deviceMatch, query: "devices") { devices in
        let match = try USBMatchingQueries.imageInterfaces()
        return try services(match, query: "image-class interfaces") { interfaces in
        let deviceDescriptors = try USBDiscoveryDiagnostics.descriptors { try devices.map {
            try USBTargetSelection.Device(id: identity($0), properties: properties($0))
        } }
        let interfaceDescriptors = try USBDiscoveryDiagnostics.descriptors { try interfaces.map {
            try USBTargetSelection.Interface(id: identity($0), deviceID: parentDeviceID($0), properties: properties($0))
        } }
        return try USBDiscoveryDiagnostics.selection { try USBTargetSelection.withSelection(devices: deviceDescriptors, interfaces: interfaceDescriptors,
                                                     expected: expected) { selection in
            guard let index = interfaceDescriptors.firstIndex(where: { $0.id == selection.interfaceID }) else {
                throw USBDiscoveryFailure(.interfaceValidation, "selected registry service", detail: "selected service disappeared")
            }
            return try body(interfaces[index], selection)
        } }
        }
        }
    }
    public static func findUniqueTarget() throws -> Target {
        try selected { service, selection in
            let code = IOObjectRetain(service)
            try USBDiscoveryDiagnostics.require(code == kIOReturnSuccess, stage: .interfaceValidation,
                operation: "IOObjectRetain", code: code, detail: "retaining selected service failed")
            return Target(service: service, identity: selection)
        }
    }
    public static func openTarget(_ target: Target) throws -> MTPDevice {
        // Rescan after the existing pre-session delay. Retained registry identity
        // must still match; unplug/replacement/ambiguity never triggers fallback.
        try selected(expected: target.identity) { service, _ in
            guard try identity(target.service) == identity(service) else {
                throw USBTargetSelection.Rejection.identityChanged
            }
            return try MTPDevice(service: service)
        }
    }
}
