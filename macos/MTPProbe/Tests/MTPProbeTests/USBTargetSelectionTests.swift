import XCTest
@testable import MTPProbeLib

final class USBTargetSelectionTests: XCTestCase {
    private func device(_ id: UInt64 = 10, vendor: Int = 0x04E8, product: Int = 0x6860) throws -> USBTargetSelection.Device {
        try .init(id: id, properties: ["idVendor": vendor, "idProduct": product])
    }
    private func properties() -> [String: Any] {
        ["bInterfaceNumber": 0, "bInterfaceClass": 6, "bInterfaceSubClass": 1, "bInterfaceProtocol": 1,
         "idVendor": 0x04E8, "idProduct": 0x6860]
    }
    private func interface(_ id: UInt64 = 20, parent: UInt64 = 10) throws -> USBTargetSelection.Interface {
        try .init(id: id, deviceID: parent, properties: properties())
    }
    private func denied(_ devices: [USBTargetSelection.Device], _ interfaces: [USBTargetSelection.Interface],
                        file: StaticString = #filePath, line: UInt = #line) {
        var openings = 0
        XCTAssertThrowsError(try USBTargetSelection.withSelection(devices: devices, interfaces: interfaces) { _ in
            openings += 1
        }, file: file, line: line)
        XCTAssertEqual(openings, 0, file: file, line: line)
    }
    func testUniqueTargetOpensOnce() throws {
        var openings = 0
        let selected = try USBTargetSelection.withSelection(devices: [device()], interfaces: [interface()]) { selection in
            openings += 1; return selection
        }
        XCTAssertEqual(openings, 1)
        XCTAssertEqual(selected.deviceID, 10); XCTAssertEqual(selected.interfaceID, 20)
        XCTAssertEqual(selected.interfaceNumber, 0)
    }
    func testWrongVendorAndProductRejectedBeforeOpening() throws {
        denied([try device(vendor: 0x1234)], [try interface()])
        denied([try device(product: 0x1234)], [try interface()])
    }
    func testNoTargetOrEligibleInterface() throws {
        denied([], []); denied([try device()], [])
    }
    func testMultipleMatchingDevicesEvenWithoutSecondInterface() throws {
        denied([try device(), try device(11)], [try interface()])
    }
    func testMultipleEligibleInterfaces() throws {
        denied([try device()], [try interface(), try interface(21)])
    }
    func testCompetingPTPDeviceRejectedInEitherOrder() throws {
        let devices = [try device(), try device(11, vendor: 0x1234)]
        let interfaces = [try interface(), try interface(21, parent: 11)]
        denied(devices, interfaces); denied(Array(devices.reversed()), Array(interfaces.reversed()))
    }
    func testWrongParentOrAdvertisedIdentity() throws {
        denied([try device()], [try interface(parent: 99)])
        for key in ["idVendor", "idProduct"] {
            var props = properties(); props[key] = 1
            denied([try device()], [try .init(id: 20, deviceID: 10, properties: props)])
        }
    }
    func testUnexpectedDescriptorValues() throws {
        for key in ["bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol"] {
            var props = properties(); props[key] = 0
            denied([try device()], [try .init(id: 20, deviceID: 10, properties: props)])
        }
    }
    func testMissingMalformedInterfaceDescriptors() throws {
        for key in ["bInterfaceNumber", "bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol"] {
            var props = properties(); props.removeValue(forKey: key)
            XCTAssertThrowsError(try USBTargetSelection.Interface(id: 20, deviceID: 10, properties: props))
            for value in [true, "1", -1, 256, 1.5, Double.nan] as [Any] {
                props = properties(); props[key] = value
                XCTAssertThrowsError(try USBTargetSelection.Interface(id: 20, deviceID: 10, properties: props))
            }
        }
    }
    func testMissingMalformedDeviceDescriptors() {
        for props in [[:], ["idVendor": 0x04E8], ["idVendor": true, "idProduct": 0x6860],
                                     ["idVendor": 0x04E8, "idProduct": 65536], ["idVendor": "1256", "idProduct": 0x6860]] as [[String: Any]] {
            XCTAssertThrowsError(try USBTargetSelection.Device(id: 10, properties: props))
        }
    }
    func testChangedSnapshotRejectsOpening() throws {
        let expected = try USBTargetSelection.select(devices: [device()], interfaces: [interface()])
        var openings = 0
        XCTAssertThrowsError(try USBTargetSelection.withSelection(devices: [device()], interfaces: [interface(21)], expected: expected) { _ in openings += 1 })
        XCTAssertThrowsError(try USBTargetSelection.withSelection(devices: [device(11)], interfaces: [interface(parent: 11)], expected: expected) { _ in openings += 1 })
        XCTAssertEqual(openings, 0)
    }
    func testDuplicateRegistryIdentityRejected() throws {
        denied([try device(), try device()], [try interface()])
        denied([try device()], [try interface(), try interface()])
    }
    func testUnrelatedNonImagingDeviceDoesNotChangeUniqueSelection() throws {
        let selected = try USBTargetSelection.select(devices: [device(11, vendor: 0x1234), device()], interfaces: [interface()])
        XCTAssertEqual(selected.deviceID, 10)
    }
    func testParentIdentitySufficesWhenInterfaceDoesNotRepeatVendorProduct() throws {
        var props = properties(); props.removeValue(forKey: "idVendor"); props.removeValue(forKey: "idProduct")
        let selected = try USBTargetSelection.select(devices: [device()], interfaces: [.init(id: 20, deviceID: 10, properties: props)])
        XCTAssertEqual(selected.interfaceID, 20)
    }
}
