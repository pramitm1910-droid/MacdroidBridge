import Foundation
import XCTest
@testable import MTPProbeLib

final class MTPDiagnosticReportingTests: XCTestCase {
    func testAnnotationsRoundTripExactlyAndInOrder() throws {
        let notes = ["  screen awake; File Transfer @ 22:20 IST!  ", "", "a\nb\t\"quoted\" — ✓", "--trace-storage-ids"]
        let arguments = ["--trace-storage-ids"] + notes.flatMap { ["--note", $0] }
        let options = try MTPDiagnosticOptions(arguments: arguments)
        XCTAssertTrue(options.traceStorageIDs)
        XCTAssertEqual(options.notes, notes)
        var output: [String] = []
        MTPDiagnosticReporting(enabled: true, emit: { output.append($0) }).reportNotes(options.notes)
        XCTAssertEqual(output.map { String($0.dropFirst("note: ".count)) }, notes)
    }

    func testDiagnosticArgumentsRequireTraceForNotesAndRejectMalformedOptions() throws {
        XCTAssertFalse(try MTPDiagnosticOptions(arguments: []).traceStorageIDs)
        XCTAssertEqual(try MTPDiagnosticOptions(arguments: ["--note", "awake", "--trace-storage-ids"]).notes, ["awake"])
        for arguments in [
            ["--note", "awake"], ["--trace-storage-ids", "--note"],
            ["--trace-storage-ids", "--unknown"], ["--trace-storage-ids", "--trace-storage-ids"]
        ] {
            XCTAssertThrowsError(try MTPDiagnosticOptions(arguments: arguments))
        }
    }

    func testExactEmptySuccessLineAndDisabledReporting() {
        var output: [String] = []
        let reporter = MTPDiagnosticReporting(enabled: true, emit: { output.append($0) })
        reporter.reportStorageResult([])
        reporter.reportStorageResult([0x10001])
        let disabled = MTPDiagnosticReporting(enabled: false, emit: { output.append($0) })
        disabled.reportStorageResult([])
        disabled.reportNotes(["hidden"])
        XCTAssertEqual(output, ["result: empty-success (0x2001, count 0)"])
    }

    func testTimingUsesMonotonicClockDespiteWallClockMovingBackwards() throws {
        var walls = [Date(timeIntervalSince1970: 100), Date(timeIntervalSince1970: 90)]
        var ticks: [TimeInterval] = [10, 11.25]
        var lines: [String] = []
        let reporter = MTPDiagnosticReporting(enabled: true, clock: MTPDiagnosticClock(
            wallNow: { walls.removeFirst() }, monotonicNow: { ticks.removeFirst() }
        ), emit: { lines.append($0) })
        var calls = 0
        let value = reporter.measure("GetStorageIDs") { calls += 1; return 42 }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(lines, [
            "GetStorageIDs started: 1970-01-01T00:01:40.000Z",
            "GetStorageIDs ended: 1970-01-01T00:01:30.000Z; elapsed: 1.250000 s; completed"
        ])
    }

    func testErrorIsPreservedAndTimedWithoutLoggingItsPayload() {
        enum Failure: Error { case sensitivePayload }
        var ticks: [TimeInterval] = [0, 2]
        var lines: [String] = []
        let reporter = MTPDiagnosticReporting(enabled: true, clock: MTPDiagnosticClock(
            wallNow: { Date(timeIntervalSince1970: 0) }, monotonicNow: { ticks.removeFirst() }
        ), emit: { lines.append($0) })
        var calls = 0
        XCTAssertThrowsError(try reporter.measure("GetDeviceInfo") {
            calls += 1
            throw Failure.sensitivePayload
        }) { XCTAssertTrue($0 is Failure) }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(lines.last!.hasSuffix("elapsed: 2.000000 s; failed"))
        XCTAssertFalse(lines.joined().contains("sensitivePayload"))
    }

    func testDisabledReportingDoesNotReadClocksOrEmit() {
        let reporter = MTPDiagnosticReporting(enabled: false, clock: MTPDiagnosticClock(
            wallNow: { XCTFail("Disabled clock"); return Date() },
            monotonicNow: { XCTFail("Disabled clock"); return 0 }
        ), emit: { _ in XCTFail("Disabled output") })
        XCTAssertEqual(reporter.measure("GetStorageIDs") { 7 }, 7)
        reporter.reportEvents([0x4004])
    }

    func testEmptyEvents() {
        var lines: [String] = []
        MTPDiagnosticReporting(enabled: true, emit: { lines.append($0) }).reportEvents([])
        XCTAssertEqual(lines, ["GetDeviceInfo EventsSupported: (none)"])
    }

    func testKnownAndUnknownEventsPreserveCodes() {
        var lines: [String] = []
        MTPDiagnosticReporting(enabled: true, emit: { lines.append($0) })
            .reportEvents([0x4004, 0x4005, 0x400C, 0xFFFF])
        XCTAssertEqual(lines, ["GetDeviceInfo EventsSupported: 0x4004 (StoreAdded), 0x4005 (StoreRemoved), 0x400C (StorageInfoChanged), 0xFFFF"])
    }

    func testEmptyInventoryRemainsErrorForCLIInBothModes() {
        for enabled in [false, true] {
            let error = MTPDiagnosticReporting(enabled: enabled).emptyInventoryError
            guard case .receiveDataFailed(let message) = error else {
                return XCTFail("Must still reach CLI failure catch and exit 1")
            }
            if enabled {
                XCTAssertEqual(message, "valid empty storage response; no storage published (MTP 0x2001 OK). Inventory unavailable.")
            } else {
                XCTAssertEqual(message, "GetStorageIDs returned zero IDs. Inventory unavailable; check that the phone is unlocked and file access is allowed.")
            }
        }
    }
}
