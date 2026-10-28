import Foundation
import XCTest
@testable import MTPProbeLib

final class MTPRootListingTests: XCTestCase {
    final class Wire: MTPTransport {
        let bulkOutMaxPacketSize = 512
        var commands: [(UInt16, [UInt32])] = []
        var pending = Data()
        var handles: [UInt32] = [7, 8]
        var storageIDs: [UInt32] = [0x20002] // Deliberately not historical 0x10001.
        var rootPayload: Data?
        var oversized = false
        var unavailable = false
        var malformedInfo = false
        var wrongParent = false
        var wrongStorage = false
        var reads = 0
        var closes = 0
        func abort() {}
        func close() { closes += 1 }
        func isTerminalError(_ error: Error) -> Bool { false }
        func array(_ values: [UInt32]) -> Data {
            var w = MTPDataWriter(); w.writeUInt32(UInt32(values.count))
            for v in values { w.writeUInt32(v) }; return w.bytes
        }
        func response(_ tx: UInt32, _ code: UInt16 = 0x2001) -> Data {
            var w = MTPDataWriter(); w.writeUInt32(12); w.writeUInt16(3); w.writeUInt16(code); w.writeUInt32(tx); return w.bytes
        }
        func write(data: Data, timeout: TimeInterval) throws {
            var r = MTPDataReader(data: data)
            _ = try r.readUInt32(); _ = try r.readUInt16()
            let op = try r.readUInt16(); let tx = try r.readUInt32()
            var args: [UInt32] = []; while r.bytesRemaining > 0 { args.append(try r.readUInt32()) }
            commands.append((op,args))
            XCTAssertTrue([0x1002,0x1003,0x1004,0x1005,0x1007,0x1008].contains(op), "Forbidden opcode")
            var w = MTPDataWriter()
            switch op {
            case 0x1002, 0x1003: pending = response(tx); return
            case 0x1004: pending = MTPDataPacket.serialise(code: op, transactionID: tx, payload: array(storageIDs)) + response(tx); return
            case 0x1005:
                w.writeUInt16(3); w.writeUInt16(2); w.writeUInt16(0)
                w.writeUInt64(10000); w.writeUInt64(5000); w.writeUInt32(100)
                w.writeMTPString("Internal storage"); w.writeMTPString("")
            case 0x1007:
                if unavailable { pending = response(tx,0x2008); return }
                if oversized {
                    w.writeUInt32(1_048_577); w.writeUInt16(2); w.writeUInt16(op); w.writeUInt32(tx)
                    pending = w.bytes; return // No payload should be requested.
                }
                pending = MTPDataPacket.serialise(code: op, transactionID: tx, payload: rootPayload ?? array(handles)) + response(tx); return
            case 0x1008:
                if malformedInfo { pending = MTPDataPacket.serialise(code: op, transactionID: tx, payload: Data([0])) + response(tx); return }
                let directory = args[0] % 2 == 1
                w.writeUInt32(wrongStorage ? 0xBAD : storageIDs[0]); w.writeUInt16(directory ? 0x3001 : 0x3000)
                w.writeUInt16(0); w.writeUInt32(42); w.writeUInt16(0)
                for _ in 0..<6 { w.writeUInt32(0) }
                w.writeUInt32(wrongParent ? 5 : 0); w.writeUInt16(directory ? 1 : 0)
                w.writeUInt32(0); w.writeUInt32(0)
                w.writeMTPString(directory ? "DCIM" : "private.txt")
                w.writeMTPString(""); w.writeMTPString(""); w.writeMTPString("")
            default: throw MTPParseError.malformed("forbidden command")
            }
            pending = MTPDataPacket.serialise(code: op, transactionID: tx, payload: w.bytes) + response(tx)
        }
        func read(maxSize: Int, timeout: TimeInterval) throws -> Data {
            reads += 1
            guard !pending.isEmpty else { throw MTPParseError.malformed("unexpected extra read") }
            let result = Data(pending.prefix(maxSize)); pending.removeFirst(result.count); return result
        }
    }
    func run(_ wire: Wire) throws -> MTPRootListing.Result { try MTPRootListing.run(device: MTPDevice(transport: wire), emit: { _ in }) }
    func testFreshStorageRootSelectorMixedMetadataAndCleanup() throws {
        let w = Wire(); let result = try run(w)
        XCTAssertEqual(result.storageID,0x20002); XCTAssertEqual(result.entries.map(\.isDirectory),[true,false])
        XCTAssertEqual(result.entries.first?.filename,"DCIM"); XCTAssertTrue(result.complete)
        XCTAssertEqual(w.commands.first?.0,0x1002); XCTAssertEqual(w.commands.last?.0,0x1003)
        XCTAssertEqual(w.commands.filter { $0.0 == 0x1007 }.first?.1,[0x20002,0,0xFFFFFFFF])
        XCTAssertEqual(w.closes,1)
    }
    func testEmptyRootIsCompleteAndNoMetadataRequests() throws {
        let w=Wire(); w.handles=[]; let result=try run(w)
        XCTAssertTrue(result.complete); XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(w.commands.contains {$0.0 == 0x1008}); XCTAssertEqual(w.commands.last?.0,0x1003)
    }
    func testMoreThan32IsExplicitlyIncomplete() throws {
        let w=Wire(); w.handles=Array(1...33); let result=try run(w)
        XCTAssertEqual(result.totalHandles,33); XCTAssertEqual(result.entries.count,32); XCTAssertFalse(result.complete)
        XCTAssertEqual(w.commands.filter {$0.0 == 0x1008}.count,32)
    }
    func testInvalidAndDuplicateHandlesRejectedWithCleanup() {
        for ids: [UInt32] in [[0],[0xFFFFFFFF],[7,7]] {
            let w=Wire(); w.handles=ids; XCTAssertThrowsError(try run(w))
            XCTAssertFalse(w.commands.contains {$0.0 == 0x1008}); XCTAssertEqual(w.commands.last?.0,0x1003); XCTAssertEqual(w.closes,1)
        }
    }
    func testMalformedCountAndTrailingBytesRejected() {
        for payload in [Data([2,0,0,0,7,0,0,0]),Data([0,0,0,0,1]),Data([255,255,255,255])] {
            let w=Wire(); w.rootPayload=payload; XCTAssertThrowsError(try run(w)); XCTAssertEqual(w.closes,1)
            XCTAssertFalse(w.commands.contains {$0.0 == 0x1008})
        }
    }
    func testOversizedHeaderFailsBeforePayloadReadAndReleasesTransport() {
        let w=Wire(); w.oversized=true; XCTAssertThrowsError(try run(w))
        XCTAssertEqual(w.reads,4); XCTAssertEqual(w.closes,1); XCTAssertFalse(w.commands.contains {$0.0 == 0x1008})
    }
    func testExactOneMiBContainerAcceptedWithoutSilentTruncation() throws {
        let w=Wire(); w.handles=Array(1...262140) // 12-byte header + 4-byte count + N*4 = 1 MiB.
        let result=try run(w); XCTAssertEqual(result.totalHandles,262140); XCTAssertEqual(result.entries.count,32); XCTAssertFalse(result.complete)
    }
    func testStorageUnavailableStopsBeforeObjectInfoAndReleases() {
        let w=Wire(); w.unavailable=true; XCTAssertThrowsError(try run(w)); XCTAssertEqual(w.closes,1)
        XCTAssertFalse(w.commands.contains {$0.0 == 0x1008})
    }
    func testEmptyAndAmbiguousStorageNeverUseHistoricalID() {
        for ids: [UInt32] in [[],[0x20002,0x30003],[0x20002,0x20002],[0]] {
            let w=Wire(); w.storageIDs=ids; XCTAssertThrowsError(try run(w)); XCTAssertEqual(w.closes,1)
            XCTAssertFalse(w.commands.contains {$0.0 == 0x1007}); XCTAssertEqual(w.commands.last?.0,0x1003)
        }
    }
    func testMalformedObjectMetadataClosesSession() {
        let w=Wire(); w.malformedInfo=true; XCTAssertThrowsError(try run(w)); XCTAssertEqual(w.closes,1)
        XCTAssertEqual(w.commands.last?.0,0x1003)
    }
    func testNonRootAndWrongStorageMetadataRejected() {
        for parent in [true,false] {
            let w=Wire(); w.wrongParent=parent; w.wrongStorage = !parent
            XCTAssertThrowsError(try run(w)); XCTAssertEqual(w.commands.last?.0,0x1003); XCTAssertEqual(w.closes,1)
        }
    }
}
