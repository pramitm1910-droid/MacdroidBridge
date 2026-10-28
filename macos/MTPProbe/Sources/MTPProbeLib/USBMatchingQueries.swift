import Foundation
import IOKit

/// In-memory construction only. IOServiceGetMatchingServices consumes one
/// dictionary reference through its CF_RELEASES_ARGUMENT contract.
public enum USBMatchingQueries {
    public static func devices() throws -> CFMutableDictionary {
        guard let query = IOServiceMatching("IOUSBHostDevice") else {
            throw USBDiscoveryFailure(.queryCreation, "IOServiceMatching/IOUSBHostDevice",
                                      detail: "matching dictionary unavailable")
        }
        return query
    }
    public static func imageInterfaces() throws -> CFMutableDictionary {
        guard let query = IOServiceMatching("IOUSBHostInterface") else {
            throw USBDiscoveryFailure(.queryCreation, "IOServiceMatching/IOUSBHostInterface",
                                      detail: "matching dictionary unavailable")
        }
        // Live comparison found the same registered interface by class and ID,
        // and with IOPropertyMatch, but not with the host helper's top-level
        // bInterfaceClass criterion. Use generic registry-property matching.
        // Selection still enforces 04E8:6860, 06/01/01, uniqueness and parent ID.
        let dictionary = query as NSMutableDictionary
        dictionary[kIOPropertyMatchKey] = ["bInterfaceClass": NSNumber(value: 6)]
        return query
    }
}
