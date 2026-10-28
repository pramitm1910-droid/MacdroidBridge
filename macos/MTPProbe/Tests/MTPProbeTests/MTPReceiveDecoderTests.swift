import Foundation
import XCTest
@testable import MTPProbeLib

final class MTPReceiveDecoderTests: XCTestCase {
    private final class Source {
        var chunks: [Data]
        var calls = 0
        init(_ chunks: [Data]) { self.chunks = chunks }
        func read() -> Data? {
            defer { calls += 1 }
            return calls < chunks.count ? chunks[calls] : nil
        }
    }

    private func header(_ length: UInt32, type: UInt16 = 2, code: UInt16 = 0x1004, tx: UInt32 = 7) -> Data {
        var writer = MTPDataWriter()
        writer.writeUInt32(length)
        writer.writeUInt16(type)
        writer.writeUInt16(code)
        writer.writeUInt32(tx)
        return writer.bytes
    }
    private func packet(_ payload: Data = Data(), tx: UInt32 = 7) -> Data {
        header(UInt32(12 + payload.count), tx: tx) + payload
    }
    private func response(tx: UInt32 = 7, code: UInt16 = 0x2001) -> Data {
        header(12, type: 3, code: code, tx: tx)
    }
    private func chunks(_ bytes: Data, size: Int) -> [Data] {
        stride(from: 0, to: bytes.count, by: size).map {
            bytes.subdata(in: $0..<min($0 + size, bytes.count))
        }
    }

    func testEveryHeaderSplit() throws {
        let bytes = packet(Data([1, 2, 3]))
        for split in 1..<12 {
            let source = Source([Data(bytes.prefix(split)), Data(bytes.dropFirst(split))])
            let decoder = MTPReceiveDecoder()
            let value = try decoder.receiveStored(read: source.read)
            XCTAssertEqual(value.header.transactionID, 7)
            XCTAssertEqual(value.header.containerType, 2)
            XCTAssertEqual(try value.dataContainer().payload, Data([1, 2, 3]))
            XCTAssertEqual(decoder.unreadByteCount, 0)
        }
    }

    func testPayloadSplitIntoSingleBytes() throws {
        let payload = Data(0..<100)
        let source = Source(chunks(packet(payload), size: 1))
        let decoder = MTPReceiveDecoder()
        XCTAssertEqual(try decoder.receiveStored(read: source.read).payload, payload)
    }

    func testTwoCompleteContainersUseOneRead() throws {
        let source = Source([packet(Data([1, 0, 0, 0])) + response()])
        let decoder = MTPReceiveDecoder()
        XCTAssertEqual(try decoder.receiveStored(read: source.read).payload, Data([1, 0, 0, 0]))
        XCTAssertEqual(decoder.unreadByteCount, 12)
        XCTAssertTrue(try decoder.receiveStored(read: source.read).responseContainer().isOK)
        XCTAssertEqual(source.calls, 1)
        XCTAssertEqual(decoder.unreadByteCount, 0)
    }

    func testCompleteContainerThenPartialHeader() throws {
        let next = response(tx: 8)
        let source = Source([packet() + next.prefix(5), Data(next.dropFirst(5))])
        let decoder = MTPReceiveDecoder()
        _ = try decoder.receiveStored(read: source.read)
        XCTAssertEqual(decoder.unreadByteCount, 5)
        XCTAssertEqual(try decoder.receiveStored(read: source.read).header.transactionID, 8)
        XCTAssertEqual(source.calls, 2)
    }

    func testCompleteContainerThenPartialPayload() throws {
        let next = packet(Data([1, 2, 3, 4, 5]), tx: 8)
        let source = Source([response() + next.prefix(14), Data(next.dropFirst(14))])
        let decoder = MTPReceiveDecoder()
        _ = try decoder.receiveStored(read: source.read)
        XCTAssertEqual(decoder.unreadByteCount, 14)
        XCTAssertEqual(try decoder.receiveStored(read: source.read).payload, Data([1, 2, 3, 4, 5]))
    }

    func testManyCombinedContainersRemainOrdered() throws {
        let source = Source([(1...100).reduce(into: Data()) { $0.append(response(tx: UInt32($1))) }])
        let decoder = MTPReceiveDecoder()
        for tx: UInt32 in 1...100 {
            XCTAssertEqual(try decoder.receiveStored(read: source.read).responseContainer().transactionID, tx)
        }
        XCTAssertEqual(source.calls, 1)
        XCTAssertEqual(decoder.unreadByteCount, 0)
    }

    func testMalformedLengthsPoisonDecoderUntilExplicitReset() throws {
        for length: UInt32 in [0, 1, 11] {
            let source = Source([header(length) + response()])
            let decoder = MTPReceiveDecoder()
            XCTAssertThrowsError(try decoder.receiveStored(read: source.read)) { error in
                guard case MTPParseError.malformed = error else { return XCTFail("\(error)") }
            }
            XCTAssertTrue(decoder.isFailed)
            XCTAssertEqual(decoder.unreadByteCount, 12, "Do not silently discard trailing bytes")
            XCTAssertThrowsError(try decoder.receiveStored(read: source.read))
            XCTAssertEqual(source.calls, 1)
            decoder.reset()
            XCTAssertFalse(decoder.isFailed)
            XCTAssertEqual(decoder.unreadByteCount, 0)
            let fresh = Source([response()])
            XCTAssertTrue(try decoder.receiveStored(read: fresh.read).responseContainer().isOK)
        }
    }

    func testTruncatedHeaderAndPayloadFail() {
        for bytes in [Data(packet().prefix(5)), header(100) + Data([1, 2])] {
            let source = Source([bytes])
            let decoder = MTPReceiveDecoder()
            XCTAssertThrowsError(try decoder.receiveStored(read: source.read)) { error in
                guard case MTPFramingError.truncated = error else { return XCTFail("\(error)") }
            }
            XCTAssertTrue(decoder.isFailed)
        }
    }

    func testEmptyDataContainerIsValid() throws {
        let source = Source([packet() + response()])
        let decoder = MTPReceiveDecoder()
        var payloadCalls = 0
        let parsed = try decoder.receive(read: source.read, onPayload: { _ in payloadCalls += 1 })
        XCTAssertEqual(parsed.containerLength, 12)
        XCTAssertEqual(payloadCalls, 0)
        XCTAssertTrue(try decoder.receiveStored(read: source.read).responseContainer().isOK)
    }

    func testUnexpectedEmptyUSBReadsFailWithoutLooping() {
        for input in [[Data()], [header(13), Data()]] {
            let source = Source(input)
            let decoder = MTPReceiveDecoder()
            XCTAssertThrowsError(try decoder.receiveStored(read: source.read)) { error in
                guard case MTPFramingError.emptyTransfer = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(source.calls, input.count)
        }
    }

    func testSingleBoundaryZLPAcceptedButRepeatedZLPFails() throws {
        for repeats in [1, 2] {
            let source = Source([packet()] + Array(repeating: Data(), count: repeats) + [response()])
            let decoder = MTPReceiveDecoder()
            _ = try decoder.receiveStored(read: source.read)
            if repeats == 1 {
                XCTAssertTrue(try decoder.receiveStored(read: source.read).responseContainer().isOK)
            } else {
                XCTAssertThrowsError(try decoder.receiveStored(read: source.read))
                XCTAssertEqual(source.calls, 3)
            }
        }
    }

    func testInvalidTypeAndResponseLengthsRejectedBeforePayload() {
        for bytes in [header(12, type: 0), header(12, type: 1), header(12, type: 4),
                      header(13, type: 3), header(36, type: 3), header(UInt32.max, type: 3)] {
            let source = Source([bytes])
            let decoder = MTPReceiveDecoder()
            var payloadCalls = 0
            XCTAssertThrowsError(try decoder.receive(read: source.read, onPayload: { _ in payloadCalls += 1 }))
            XCTAssertEqual(payloadCalls, 0)
            XCTAssertEqual(source.calls, 1)
        }
    }

    func testHeaderValidationStopsBeforePayloadAndPreservesTransaction() {
        let source = Source([packet(Data([42]), tx: 99)])
        let decoder = MTPReceiveDecoder()
        var payloadCalls = 0
        XCTAssertThrowsError(try decoder.receive(read: source.read, onHeader: { header in
            XCTAssertEqual(header.transactionID, 99)
            throw MTPParseError.malformed("Expected transaction 7")
        }, onPayload: { _ in payloadCalls += 1 }))
        XCTAssertEqual(payloadCalls, 0)
        XCTAssertEqual(decoder.unreadByteCount, 1)
        XCTAssertTrue(decoder.isFailed)
    }

    func testCapturedEmptyAndNonemptyStorageExchangesAcrossSplits() throws {
        let fixtures: [(Data, [UInt32])] = [
            (Data([0x10, 0, 0, 0, 2, 0, 4, 0x10, 2, 0, 0, 0, 0, 0, 0, 0]), []),
            (Data([0x14, 0, 0, 0, 2, 0, 4, 0x10, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0]), [0x10001])
        ]
        for (data, expected) in fixtures {
            let wire = data + response(tx: 2)
            for split in 1..<wire.count {
                let source = Source([Data(wire.prefix(split)), Data(wire.dropFirst(split))])
                let decoder = MTPReceiveDecoder()
                let item = try decoder.receiveStored(read: source.read)
                var reader = MTPDataReader(data: try item.dataContainer().payload)
                XCTAssertEqual(try reader.readUInt32Array(), expected)
                XCTAssertEqual(item.header.transactionID, 2)
                XCTAssertEqual(try decoder.receiveStored(read: source.read).responseContainer().transactionID, 2)
            }
        }
    }

    func testLargeMetadataBeyondUSBReadSize() throws {
        var writer = MTPDataWriter()
        writer.writeUInt32(20_000)
        for id: UInt32 in 0..<20_000 { writer.writeUInt32(id) }
        let source = Source(chunks(packet(writer.bytes) + response(), size: 65_536))
        let decoder = MTPReceiveDecoder()
        var reader = MTPDataReader(data: try decoder.receiveStored(read: source.read).dataContainer().payload)
        XCTAssertEqual(try reader.readUInt32Array(), Array(UInt32(0)..<20_000))
        XCTAssertTrue(try decoder.receiveStored(read: source.read).responseContainer().isOK)
        XCTAssertLessThanOrEqual(decoder.peakBufferedByteCount, 65_548)
    }

    func testLargePayloadStreamsWithBoundedBuffering() throws {
        let size = 32 * 1024 * 1024
        var remaining = size
        var first = true
        var received = 0
        let chunk = Data(repeating: 0xA5, count: 65_536)
        let decoder = MTPReceiveDecoder()
        let parsed = try decoder.receive(read: {
            if first { first = false; return self.header(UInt32(size + 12)) }
            guard remaining > 0 else { return nil }
            let count = min(remaining, chunk.count)
            remaining -= count
            return Data(chunk.prefix(count))
        }, onPayload: { bytes in
            XCTAssertLessThanOrEqual(bytes.count, 65_536)
            XCTAssertEqual(bytes.first, 0xA5)
            received += bytes.count
        })
        XCTAssertEqual(received, size)
        XCTAssertEqual(parsed.containerLength, UInt32(size + 12))
        XCTAssertLessThanOrEqual(decoder.peakBufferedByteCount, 65_548)
    }

    func testHugeDeclaredLengthDoesNotAllocatePayload() {
        let decoder = MTPReceiveDecoder()
        let source = Source([header(UInt32.max - 1), Data([1])])
        var bytes = 0
        XCTAssertThrowsError(try decoder.receive(read: source.read, onPayload: { bytes += $0.count }))
        XCTAssertEqual(bytes, 1)
        XCTAssertLessThanOrEqual(decoder.peakBufferedByteCount, 24)
    }

    func testSourceAndSinkFailuresLatchWithoutRetry() {
        enum Failure: Error { case injected }
        for failSource in [true, false] {
            let decoder = MTPReceiveDecoder()
            var reads = 0
            XCTAssertThrowsError(try decoder.receive(read: {
                reads += 1
                if failSource { throw Failure.injected }
                return self.packet(Data([1]))
            }, onPayload: { _ in throw Failure.injected }))
            XCTAssertTrue(decoder.isFailed)
            XCTAssertThrowsError(try decoder.receive(read: { reads += 1; return nil }, onPayload: { _ in }))
            XCTAssertEqual(reads, 1)
        }
    }

    func testStoredMappingSurvivesSpoolCleanupAndPreservesFollowingResponse() throws {
        let payload = Data(repeating: 0xAB, count: 200_000)
        let source = Source(chunks(packet(payload) + response(code: 0x2008), size: 32_768))
        let decoder = MTPReceiveDecoder()
        let stored = try decoder.receiveStored(read: source.read)
        let reply = try decoder.receiveStored(read: source.read).responseContainer()
        XCTAssertEqual(reply.responseCode, 0x2008)
        XCTAssertEqual(stored.payload, payload)
    }

    func testOversizedSourceReadFailsExplicitly() {
        let decoder = MTPReceiveDecoder(maximumReadSize: 16)
        let source = Source([Data(repeating: 0, count: 17)])
        XCTAssertThrowsError(try decoder.receiveStored(read: source.read)) { error in
            guard case MTPFramingError.oversizedRead(17) = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(decoder.isFailed)
    }

    func testConnectionsDoNotShareUnreadBytesOrFailureState() throws {
        let first = MTPReceiveDecoder()
        let second = MTPReceiveDecoder()
        let source = Source([packet() + response(tx: 42)])
        _ = try first.receiveStored(read: source.read)
        let invalid = Source([header(0)])
        XCTAssertThrowsError(try second.receiveStored(read: invalid.read))
        XCTAssertFalse(first.isFailed)
        XCTAssertEqual(try first.receiveStored(read: source.read).responseContainer().transactionID, 42)
        XCTAssertEqual(source.calls, 1)
    }

    func testPartialSpoolIsRemovedAfterTruncation() throws {
        let manager = FileManager.default
        func spools() throws -> Set<String> {
            Set(try manager.contentsOfDirectory(atPath: manager.temporaryDirectory.path)
                .filter { $0.hasPrefix("mtp-receive-") })
        }
        let before = try spools()
        let source = Source([header(1000), Data(repeating: 1, count: 20)])
        let decoder = MTPReceiveDecoder()
        XCTAssertThrowsError(try decoder.receiveStored(read: source.read))
        XCTAssertTrue(decoder.isFailed)
        XCTAssertEqual(try spools(), before)
    }
}
