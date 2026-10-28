import XCTest
@testable import MTPProbeLib

final class USBDiscoveryDiagnosticsTests: XCTestCase {
    private final class Registry {
        var code: Int32 = 0
        var iterator: UInt32 = 9
        var entries: [UInt32] = [10, 11, 0]
        var valid = true
        var releases: [UInt32] = []
        var openings = 0
        func run(_ body: ([UInt32]) throws -> Void) throws {
            try USBDiscoveryDiagnostics.withServices(query: "synthetic", acquire: { (self.code, self.iterator) },
                next: { _ in self.entries.removeFirst() }, isValid: { _ in self.valid },
                release: { self.releases.append($0) }, body: body)
        }
    }
    func testSuccessfulAcquisitionTraversalAndRelease() throws {
        let r = Registry()
        try r.run { services in
            XCTAssertEqual(services, [10, 11]); XCTAssertTrue(r.releases.isEmpty)
            r.openings += 1
        }
        XCTAssertEqual(r.openings, 1); XCTAssertEqual(r.releases, [10, 11, 9])
    }
    func testAcquisitionFailurePreservesCodeAndReleasesIterator() {
        let r = Registry(); r.code = Int32(bitPattern: 0xe00002c1)
        XCTAssertThrowsError(try r.run { _ in r.openings += 1 }) { error in
            let e = error as? USBDiscoveryFailure
            XCTAssertEqual(e?.stage, .iteratorAcquisition); XCTAssertEqual(e?.code, r.code)
            XCTAssertTrue(e?.description.contains("0xE00002C1") == true)
            XCTAssertTrue(e?.description.contains("IOServiceGetMatchingServices") == true)
        }
        XCTAssertEqual(r.openings, 0); XCTAssertEqual(r.releases, [9])
    }
    func testNullIteratorWithSuccessReturnsEmptyWithoutTraversal() throws {
        let r = Registry(); r.iterator = 0
        try r.run { services in XCTAssertTrue(services.isEmpty) }
        XCTAssertEqual(r.entries, [10, 11, 0]) // no IOIteratorNext call
        XCTAssertEqual(r.openings, 0); XCTAssertTrue(r.releases.isEmpty)
    }
    func testNullIteratorCannotOpenTransportWithoutEligibleInterface() throws {
        let r = Registry(); r.iterator = 0
        let device = try USBTargetSelection.Device(id: 1, properties: ["idVendor": 0x04E8, "idProduct": 0x6860])
        XCTAssertThrowsError(try r.run { services in
            XCTAssertTrue(services.isEmpty)
            try USBDiscoveryDiagnostics.selection {
                try USBTargetSelection.withSelection(devices: [device], interfaces: []) { _ in r.openings += 1 }
            }
        }) { error in
            let e = error as? USBDiscoveryFailure
            XCTAssertEqual(e?.stage, .interfaceValidation); XCTAssertNil(e?.code)
            XCTAssertTrue(e?.detail.contains("noInterface") == true)
        }
        XCTAssertEqual(r.openings, 0); XCTAssertTrue(r.releases.isEmpty)
    }
    func testInvalidTraversalReleasesAccumulatedServicesAndDoesNotOpen() {
        let r = Registry(); r.valid = false
        XCTAssertThrowsError(try r.run { _ in r.openings += 1 }) { error in
            let e = error as? USBDiscoveryFailure
            XCTAssertEqual(e?.stage, .iteratorTraversal); XCTAssertNil(e?.code)
            XCTAssertTrue(e?.description.contains("no separate") == true)
        }
        XCTAssertEqual(r.openings, 0); XCTAssertEqual(r.releases, [10, 11, 9])
    }
    func testEmptyValidTraversalIsSuccessful() throws {
        let r = Registry(); r.entries = [0]
        try r.run { XCTAssertTrue($0.isEmpty) }
        XCTAssertEqual(r.releases, [9])
    }
    func testBodyFailureReleasesAllHandles() {
        let r = Registry()
        XCTAssertThrowsError(try r.run { _ in
            throw USBDiscoveryFailure(.descriptorAccess, "synthetic properties", code: -1, detail: "failure")
        })
        XCTAssertEqual(r.releases, [10, 11, 9])
    }
    func testNestedAcquisitionFailureReleasesOuterServices() {
        let outer = Registry(), inner = Registry(); inner.iterator = 8; inner.code = 5
        XCTAssertThrowsError(try outer.run { _ in try inner.run { _ in inner.openings += 1 } })
        XCTAssertEqual(outer.releases, [10, 11, 9]); XCTAssertEqual(inner.releases, [8]); XCTAssertEqual(inner.openings, 0)
    }
    func testMissingAndMalformedDescriptorsHaveDescriptorStage() {
        for props in [[:], ["idVendor": "private-device-name", "idProduct": 0x6860]] as [[String: Any]] {
            let r = Registry()
            XCTAssertThrowsError(try r.run { _ in
                _ = try USBDiscoveryDiagnostics.descriptors { try USBTargetSelection.Device(id: 1, properties: props) }
                r.openings += 1
            }) { error in
                let e = error as? USBDiscoveryFailure
                XCTAssertEqual(e?.stage, .descriptorAccess); XCTAssertNil(e?.code)
                XCTAssertFalse(String(describing: error).contains("private-device-name"))
            }
            XCTAssertEqual(r.openings, 0); XCTAssertEqual(r.releases, [10, 11, 9])
        }
    }
    func testAmbiguousDeviceAndInterfaceSelectionReportedWithoutOpening() throws {
        let d = try USBTargetSelection.Device(id: 1, properties: ["idVendor": 0x04E8, "idProduct": 0x6860])
        let d2 = try USBTargetSelection.Device(id: 2, properties: ["idVendor": 0x04E8, "idProduct": 0x6860])
        let p = ["bInterfaceNumber": 0, "bInterfaceClass": 6, "bInterfaceSubClass": 1, "bInterfaceProtocol": 1]
        let i = try USBTargetSelection.Interface(id: 3, deviceID: 1, properties: p)
        let i2 = try USBTargetSelection.Interface(id: 4, deviceID: 1, properties: p)
        for (devices, interfaces) in [([d,d2],[i]), ([d],[i,i2])] {
            let r = Registry()
            XCTAssertThrowsError(try r.run { _ in
                try USBDiscoveryDiagnostics.selection {
                    try USBTargetSelection.withSelection(devices: devices, interfaces: interfaces) { _ in r.openings += 1 }
                }
            }) { error in XCTAssertEqual((error as? USBDiscoveryFailure)?.stage, .interfaceValidation) }
            XCTAssertEqual(r.openings, 0); XCTAssertEqual(r.releases, [10, 11, 9])
        }
    }
    func testQueryCreationHasNoInventedCodeAndReadableOSName() {
        XCTAssertThrowsError(try USBDiscoveryDiagnostics.require(false, stage: .queryCreation,
            operation: "IOServiceMatching", detail: "nil dictionary")) { error in
            let e = error as? USBDiscoveryFailure
            XCTAssertEqual(e?.stage, .queryCreation); XCTAssertNil(e?.code)
            XCTAssertTrue(e?.description.contains("unavailable") == true)
        }
        let known = USBDiscoveryFailure(.descriptorAccess, "synthetic", code: 4, detail: "failed")
        XCTAssertTrue(known.description.contains("0x00000004"))
        XCTAssertFalse(known.description.contains("unknown OS error"))
    }
}
