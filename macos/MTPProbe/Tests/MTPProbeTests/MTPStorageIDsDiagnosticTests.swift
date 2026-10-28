import Foundation
import XCTest
@testable import MTPProbeLib

final class MTPStorageIDsDiagnosticTests: XCTestCase {
    private final class MockTransport: MTPTransport {
        let bulkOutMaxPacketSize = 512
        var reads: [Data] = []
        var writes: [Data] = []
        var readCount = 0
        func write(data: Data, timeout: TimeInterval) throws { writes.append(data) }
        func read(maxSize: Int, timeout: TimeInterval) throws -> Data {
            readCount += 1
            return reads.removeFirst()
        }
        func abort() {}
        func close() {}
        func isTerminalError(_ error: Error) -> Bool { false }
    }

    private func response(_ tx: UInt32, code: UInt16 = MTPResponseCode.ok.rawValue) -> Data {
        var writer = MTPDataWriter()
        writer.writeUInt32(12)
        writer.writeUInt16(MTPContainerType.response.rawValue)
        writer.writeUInt16(code)
        writer.writeUInt32(tx)
        return writer.bytes
    }

    private func storagePayload(_ ids: [UInt32]) -> Data {
        var writer = MTPDataWriter()
        writer.writeUInt32(UInt32(ids.count))
        for id in ids { writer.writeUInt32(id) }
        return writer.bytes
    }

    private func open(_ transport: MockTransport) throws -> MTPDevice {
        transport.reads = [response(0)]
        let device = MTPDevice(transport: transport)
        try device.openSession()
        transport.reads = []
        transport.writes = []
        transport.readCount = 0
        return device
    }

    func testDefaultPathDoesNotEmitDiagnosticAndPreservesExchange() throws {
        let transport = MockTransport()
        let device = try open(transport)
        let payload = storagePayload([])
        transport.reads = [MTPDataPacket.serialise(code: MTPOperationCode.getStorageIDs.rawValue,
                                                   transactionID: 1, payload: payload) + response(1)]

        XCTAssertEqual(try device.getStorageIDs(), [])
        XCTAssertEqual(transport.writes, [MTPCommandContainer(code: .getStorageIDs, transactionID: 1).serialise()])
        XCTAssertEqual(transport.readCount, 1)
    }

    func testEmptyResponseCapturesExactScopedBytesAndLengths() throws {
        let transport = MockTransport()
        let device = try open(transport)
        let payload = storagePayload([])
        let data = MTPDataPacket.serialise(code: MTPOperationCode.getStorageIDs.rawValue,
                                           transactionID: 1, payload: payload)
        let final = response(1)
        transport.reads = [Data(data.prefix(7)), Data(data.dropFirst(7)) + final]
        var captures: [MTPStorageIDsDiagnostic] = []

        XCTAssertEqual(try device.getStorageIDs(onDiagnostic: { captures.append($0) }), [])
        XCTAssertEqual(captures.count, 1)
        let capture = try XCTUnwrap(captures.first)
        XCTAssertEqual(capture.command, MTPCommandContainer(code: .getStorageIDs, transactionID: 1).serialise())
        XCTAssertEqual(capture.bulkInTransferLengths, [7, data.count - 7 + final.count])
        XCTAssertEqual(capture.dataContainer, data)
        XCTAssertEqual(capture.storageArrayPayload, payload)
        XCTAssertEqual(capture.decodedStorageCount, 0)
        XCTAssertEqual(capture.responseContainer, final)
        XCTAssertEqual(capture.responseCode, MTPResponseCode.ok.rawValue)
        XCTAssertEqual(transport.readCount, 2)
    }

    func testNonemptyTraceExcludesNextTransactionFromCoalescedRead() throws {
        let transport = MockTransport()
        let device = try open(transport)
        let firstPayload = storagePayload([0x10001])
        let firstData = MTPDataPacket.serialise(code: MTPOperationCode.getStorageIDs.rawValue,
                                                transactionID: 1, payload: firstPayload)
        let secondPayload = storagePayload([0x20002])
        let secondData = MTPDataPacket.serialise(code: MTPOperationCode.getStorageIDs.rawValue,
                                                 transactionID: 2, payload: secondPayload)
        let combined = firstData + response(1) + secondData + response(2)
        transport.reads = [combined]
        var captures: [MTPStorageIDsDiagnostic] = []

        XCTAssertEqual(try device.getStorageIDs(onDiagnostic: { captures.append($0) }), [0x10001])
        XCTAssertEqual(try device.getStorageIDs(), [0x20002])
        XCTAssertEqual(captures.count, 1)
        let capture = try XCTUnwrap(captures.first)
        XCTAssertEqual(capture.bulkInTransferLengths, [combined.count])
        XCTAssertEqual(capture.dataContainer, firstData)
        XCTAssertEqual(capture.storageArrayPayload, firstPayload)
        XCTAssertEqual(capture.decodedStorageCount, 1)
        XCTAssertEqual(capture.responseContainer, response(1))
        XCTAssertFalse(capture.report.contains("02 00 02 00"))
        XCTAssertEqual(transport.readCount, 1)
        XCTAssertEqual(transport.writes, [
            MTPCommandContainer(code: .getStorageIDs, transactionID: 1).serialise(),
            MTPCommandContainer(code: .getStorageIDs, transactionID: 2).serialise()
        ])
    }

    func testResponseOnlyErrorCapturesCodeWithoutInventingStoragePayload() throws {
        let transport = MockTransport()
        let device = try open(transport)
        transport.reads = [response(1, code: 0x2002)]
        var captures: [MTPStorageIDsDiagnostic] = []

        XCTAssertThrowsError(try device.getStorageIDs(onDiagnostic: { captures.append($0) }))
        let capture = try XCTUnwrap(captures.first)
        XCTAssertNil(capture.dataContainer)
        XCTAssertNil(capture.storageArrayPayload)
        XCTAssertNil(capture.decodedStorageCount)
        XCTAssertEqual(capture.responseContainer, response(1, code: 0x2002))
        XCTAssertEqual(capture.responseCode, 0x2002)
        XCTAssertEqual(transport.writes.count, 1)
    }

    func testReportingDistinguishesEmptySuccessFromProtocolErrorWithoutRetry() throws {
        for code: UInt16 in [0x2001, 0x2002] {
            let transport = MockTransport()
            let device = try open(transport)
            let data = MTPDataPacket.serialise(code: MTPOperationCode.getStorageIDs.rawValue,
                                               transactionID: 1, payload: storagePayload([]))
            transport.reads = [data + response(1, code: code)]
            var lines: [String] = []
            let reporter = MTPDiagnosticReporting(enabled: true, emit: { lines.append($0) })
            XCTAssertThrowsError(try {
                let ids = try reporter.measure("GetStorageIDs") {
                    try device.getStorageIDs(onDiagnostic: { lines.append($0.report) })
                }
                reporter.reportStorageResult(ids)
                if ids.isEmpty { throw reporter.emptyInventoryError }
            }()) { error in
                if code == 0x2001 {
                    XCTAssertTrue(String(describing: error).contains("valid empty storage response; no storage published"))
                } else {
                    XCTAssertFalse(String(describing: error).contains("no storage published"))
                }
            }
            XCTAssertEqual(lines.contains("result: empty-success (0x2001, count 0)"), code == 0x2001)
            XCTAssertTrue(lines.contains { $0.hasSuffix(code == 0x2001 ? "; completed" : "; failed") })
            XCTAssertEqual(transport.writes, [MTPCommandContainer(code: .getStorageIDs, transactionID: 1).serialise()])
        }
    }
}
