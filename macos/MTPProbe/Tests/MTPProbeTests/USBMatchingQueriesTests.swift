import XCTest
import Foundation
import CoreFoundation
@testable import MTPProbeLib

final class USBMatchingQueriesTests: XCTestCase {
    // Helpers allocate dictionaries only; no registry or USB query is performed.
    func testDeviceDictionaryServiceClass() throws {
        let query = try USBMatchingQueries.devices() as NSDictionary
        XCTAssertEqual(query["IOProviderClass"] as? String, "IOUSBHostDevice")
        XCTAssertEqual(Set(query.allKeys.compactMap { $0 as? String }), ["IOProviderClass"])
    }
    func testInterfaceClassUsesIOPropertyMatchRegression() throws {
        let query = try USBMatchingQueries.imageInterfaces() as NSDictionary
        print("Synthetic corrected query: \(query)")
        XCTAssertEqual(query["IOProviderClass"] as? String, "IOUSBHostInterface")
        XCTAssertEqual(Set(query.allKeys.compactMap { $0 as? String }), ["IOProviderClass", "IOPropertyMatch"])
        let properties = try XCTUnwrap(query["IOPropertyMatch"] as? NSDictionary)
        XCTAssertEqual(Set(properties.allKeys.compactMap { $0 as? String }), ["bInterfaceClass"])
        let value = try XCTUnwrap(properties["bInterfaceClass"] as? NSNumber)
        XCTAssertEqual(value.intValue, 6)
        XCTAssertNotEqual(CFGetTypeID(value), CFBooleanGetTypeID())
        // Reintroducing the old top-level constraint must fail this regression.
        XCTAssertNil(query["bInterfaceClass"])
        XCTAssertNil(query["idVendor"]); XCTAssertNil(query["idProduct"])
    }
    func testReturnedDictionarySurvivesPoolAndCallsAreIndependent() throws {
        let first: NSDictionary = try autoreleasepool { try USBMatchingQueries.imageInterfaces() as NSDictionary }
        let copy = first.mutableCopy() as! NSMutableDictionary
        copy["IOPropertyMatch"] = ["bInterfaceClass": NSNumber(value: 255)]
        let second = try USBMatchingQueries.imageInterfaces() as NSDictionary
        for query in [first, second] {
            let properties = try XCTUnwrap(query["IOPropertyMatch"] as? NSDictionary)
            XCTAssertEqual((properties["bInterfaceClass"] as? NSNumber)?.intValue, 6)
        }
    }
}
