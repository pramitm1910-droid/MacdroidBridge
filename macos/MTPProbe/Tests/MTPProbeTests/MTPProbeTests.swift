import XCTest
@testable import MTPProbeLib

final class MTPProbeTests: XCTestCase {
    func testSendObjectInfoOperationIsRecognized() {
        XCTAssertEqual(MTPOperationCode.sendObjectInfo.rawValue, 0x100C)
    }

    func testSendObjectOperationIsRecognized() {
        XCTAssertEqual(MTPOperationCode.sendObject.rawValue, 0x100D)
    }

    func testSendObjectInfoDataPacketSerialises() {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let packet = MTPDataPacket.serialise(code: MTPOperationCode.sendObjectInfo.rawValue, transactionID: 7, payload: payload)

        XCTAssertEqual(packet.count, 16)
        XCTAssertEqual(packet.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }, UInt32(16).littleEndian)
        XCTAssertEqual(packet.dropFirst(4).prefix(2).withUnsafeBytes { $0.load(as: UInt16.self) }, MTPContainerType.data.rawValue)
        XCTAssertEqual(packet.dropFirst(6).prefix(2).withUnsafeBytes { $0.load(as: UInt16.self) }, MTPOperationCode.sendObjectInfo.rawValue)
        XCTAssertEqual(packet.dropFirst(8).prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }, UInt32(7).littleEndian)
        XCTAssertEqual(packet.dropFirst(12), payload)
    }

    func testSendObjectDataPacketSerialises() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let packet = MTPDataPacket.serialise(code: MTPOperationCode.sendObject.rawValue, transactionID: 11, payload: payload)

        XCTAssertEqual(packet.count, 16)
        XCTAssertEqual(packet.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }, UInt32(16).littleEndian)
        XCTAssertEqual(packet.dropFirst(4).prefix(2).withUnsafeBytes { $0.load(as: UInt16.self) }, MTPContainerType.data.rawValue)
        XCTAssertEqual(packet.dropFirst(6).prefix(2).withUnsafeBytes { $0.load(as: UInt16.self) }, MTPOperationCode.sendObject.rawValue)
        XCTAssertEqual(packet.dropFirst(8).prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }, UInt32(11).littleEndian)
        XCTAssertEqual(packet.dropFirst(12), payload)
    }

    func testSendObjectEmptyDataPacketSerialisesHeaderWithoutPayload() {
        let packet = MTPDataPacket.serialise(code: MTPOperationCode.sendObject.rawValue, transactionID: 11, payload: Data())

        XCTAssertEqual(packet.count, 12)
        switch MTPContainerHeader.parse(from: packet) {
        case .failure(let error):
            XCTFail("Header parse failed: \(error)")
        case .success(let header):
            XCTAssertEqual(header.containerLength, 12)
            XCTAssertEqual(header.containerType, MTPContainerType.data.rawValue)
            XCTAssertEqual(header.code, MTPOperationCode.sendObject.rawValue)
            XCTAssertEqual(header.transactionID, 11)
        }
        XCTAssertTrue(packet.dropFirst(12).isEmpty)
    }

    func testSendObjectInfoDatasetSerialises() {
        let dataset = MTPObjectInfoDataset.serialise(
            storageID: 1,
            parentObject: 0xFFFFFFFF,
            objectFormat: 0x3000,
            filename: "hello.txt",
            fileSize: 4,
            protectionStatus: 0
        )

        var reader = MTPDataReader(data: dataset)
        XCTAssertEqual(try reader.readUInt32(), 1)
        XCTAssertEqual(try reader.readUInt16(), 0x3000)
        XCTAssertEqual(try reader.readUInt16(), 0)
        XCTAssertEqual(try reader.readUInt32(), 4)
        XCTAssertEqual(try reader.readUInt16(), 0)
        XCTAssertEqual(try reader.readUInt32(), 0)
        XCTAssertEqual(try reader.readUInt32(), 0)
        XCTAssertEqual(try reader.readUInt32(), 0)
        XCTAssertEqual(try reader.readUInt32(), 0)
        XCTAssertEqual(try reader.readUInt32(), 0)
        XCTAssertEqual(try reader.readUInt32(), 0)
        XCTAssertEqual(try reader.readUInt32(), 0xFFFFFFFF)
        XCTAssertEqual(try reader.readUInt16(), 0)
        XCTAssertEqual(try reader.readUInt32(), 0)
        XCTAssertEqual(try reader.readUInt32(), 0)
        XCTAssertEqual(try reader.readMTPString(), "hello.txt")
    }

    func testGetObjectOperationIsRecognized() {
        XCTAssertEqual(MTPOperationCode.getObject.rawValue, 0x1009)
    }

    func testGetObjectInfoOperationIsRecognized() {
        XCTAssertEqual(MTPOperationCode.getObjectInfo.rawValue, 0x1008)
    }

    func testGetObjectCommandSerialisesHandleParameter() {
        let handle: UInt32 = 0x0001002A
        let command = MTPCommandContainer(code: .getObject, transactionID: 9, parameters: [handle])
        let packet = command.serialise()

        XCTAssertEqual(packet.count, 16)
        switch MTPContainerHeader.parse(from: packet) {
        case .failure(let error):
            XCTFail("Header parse failed: \(error)")
        case .success(let header):
            XCTAssertEqual(header.containerLength, 16)
            XCTAssertEqual(header.containerType, MTPContainerType.command.rawValue)
            XCTAssertEqual(header.code, MTPOperationCode.getObject.rawValue)
            XCTAssertEqual(header.transactionID, 9)
        }

        let unpackedHandle = packet.dropFirst(12).prefix(4).withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        XCTAssertEqual(unpackedHandle, handle)
    }

    func testGetObjectInfoCommandSerialisesHandleParameter() {
        let handle: UInt32 = 0x00020001
        let command = MTPCommandContainer(code: .getObjectInfo, transactionID: 3, parameters: [handle])
        let packet = command.serialise()

        switch MTPContainerHeader.parse(from: packet) {
        case .failure(let error):
            XCTFail("Header parse failed: \(error)")
        case .success(let header):
            XCTAssertEqual(header.containerType, MTPContainerType.command.rawValue)
            XCTAssertEqual(header.code, MTPOperationCode.getObjectInfo.rawValue)
            XCTAssertEqual(header.transactionID, 3)
        }

        let unpackedHandle = packet.dropFirst(12).prefix(4).withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        XCTAssertEqual(unpackedHandle, handle)
    }

    func testGetObjectDataContainerParsesPayload() {
        let payload = Data([0x11, 0x22, 0x33, 0x44])
        let packet = MTPDataPacket.serialise(code: MTPOperationCode.getObject.rawValue, transactionID: 9, payload: payload)

        switch MTPDataContainer.parse(from: packet) {
        case .failure(let error):
            XCTFail("Data container parse failed: \(error)")
        case .success(let container):
            XCTAssertEqual(container.operationCode, MTPOperationCode.getObject.rawValue)
            XCTAssertEqual(container.transactionID, 9)
            XCTAssertEqual(container.payload, payload)
        }
    }

    func testGetObjectInfoDatasetUnpacksFilenameAndHandle() throws {
        let dataset = MTPObjectInfoDataset.serialise(
            storageID: 0x00010001,
            parentObject: 0xFFFFFFFF,
            objectFormat: 0x3000,
            filename: "AndroidMacBridge_test.txt",
            fileSize: 28,
            protectionStatus: 0
        )
        let info = try MTPObjectInfo.parse(objectHandle: 0x42, from: dataset)
        XCTAssertEqual(info.objectHandle, 0x42)
        XCTAssertEqual(info.storageID, 0x00010001)
        XCTAssertEqual(info.filename, "AndroidMacBridge_test.txt")
        XCTAssertEqual(info.objectCompressedSize, 28)
        XCTAssertFalse(info.isDirectory)
    }

    func testStorageSelectorPrefersWritableSamsungStorage() {
        let storageInfos: [UInt32: MTPStorageInfo] = [
            0x0001: MTPStorageInfo(storageID: 0x0001, storageType: 0x0004, filesystemType: 0x0000, accessCapability: MTPAccessCapability.readOnlyWithDeletion.rawValue, maxCapacity: 0, freeSpaceInBytes: 0, freeSpaceInObjects: 0, storageDescription: "Internal", volumeIdentifier: ""),
            0x10001: MTPStorageInfo(storageID: 0x10001, storageType: 0x0004, filesystemType: 0x0000, accessCapability: MTPAccessCapability.readWrite.rawValue, maxCapacity: 0, freeSpaceInBytes: 0, freeSpaceInObjects: 0, storageDescription: "Samsung Storage", volumeIdentifier: "")
        ]

        let selected = MTPStorageSelector.chooseStorageID(
            requestedStorageID: 0,
            allStorageIDs: [0x0001, 0x10001],
            storageInfoByID: storageInfos
        )

        XCTAssertEqual(selected, 0x10001)
    }

    // MARK: - Transaction ID Sequencing Regression Tests

    /// Verify that successive MTPCommandContainers can carry distinct, sequential transaction IDs
    /// and that each serialised packet embeds the correct ID. This catches the prior bug where
    /// every command hardcoded transactionID=1.
    func testSequentialTransactionIDsSerialiseDistinctly() {
        let ids: [UInt32] = [1, 2, 3, 4, 5]
        for id in ids {
            let command = MTPCommandContainer(code: .getStorageIDs, transactionID: id)
            let packet = command.serialise()
            let embeddedID = packet.dropFirst(8).prefix(4).withUnsafeBytes {
                UInt32(littleEndian: $0.load(as: UInt32.self))
            }
            XCTAssertEqual(embeddedID, id, "Transaction ID in serialised command should be \(id)")
        }
    }

    /// Exercise the allocator type held and used by MTPDevice, rather than supplying
    /// hand-picked IDs directly to packet serialization.
    func testMTPDeviceTransactionAllocatorStartsAtOneAndIncrements() {
        var allocator = MTPTransactionIDAllocator()

        XCTAssertEqual(allocator.allocate(), 1)
        XCTAssertEqual(allocator.allocate(), 2)
        XCTAssertEqual(allocator.allocate(), 3)
    }

    func testMTPDeviceTransactionAllocatorWrapsWithoutAllocatingZero() {
        var allocator = MTPTransactionIDAllocator(startingAt: UInt32.max)

        XCTAssertEqual(allocator.allocate(), UInt32.max)
        XCTAssertEqual(allocator.allocate(), 1)
    }

    func testOpenSessionUsesTransactionIDZeroBeforeAllocatorStartsAtOne() {
        let command = MTPCommandContainer(
            code: .openSession,
            transactionID: MTPTransactionIDAllocator.openSessionTransactionID,
            parameters: [1]
        )
        let packet = command.serialise()
        let transactionID = UInt32(littleEndian: packet.dropFirst(8).prefix(4).withUnsafeBytes {
            $0.load(as: UInt32.self)
        })
        var allocator = MTPTransactionIDAllocator()

        XCTAssertEqual(transactionID, 0)
        XCTAssertEqual(allocator.allocate(), 1)
    }

    /// Verify that the command, data, and response phases of a transfer all embed the same
    /// transaction ID.  Prior code used separate hardcoded values.
    func testCommandAndDataContainerShareTransactionID() {
        let txID: UInt32 = 7
        let command = MTPCommandContainer(code: .sendObjectInfo, transactionID: txID, parameters: [0x10001, 0xFFFFFFFF])
        let commandPacket = command.serialise()
        let dataPacket = MTPDataPacket.serialise(
            code: MTPOperationCode.sendObjectInfo.rawValue,
            transactionID: txID,
            payload: Data([0x01, 0x02])
        )

        let cmdTxID = commandPacket.dropFirst(8).prefix(4).withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        }
        let dataTxID = dataPacket.dropFirst(8).prefix(4).withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        }
        XCTAssertEqual(cmdTxID, txID)
        XCTAssertEqual(dataTxID, txID)
        XCTAssertEqual(cmdTxID, dataTxID, "Command and data phase must carry the same transaction ID")
    }

    // MARK: - SessionAlreadyOpen Response Parsing

    /// Parse a synthetic 0x201E SessionAlreadyOpen response and verify the existing session ID
    /// is extracted from parameter[0].  This tests the response format that the fixed
    /// openSession() now relies on.
    func testSessionAlreadyOpenResponseCarriesExistingSessionID() {
        // Build a 16-byte response container:
        //   Length=16, Type=0x0003 (response), Code=0x201E, TxID=0, Param[0]=existingSessionID
        let existingSessionID: UInt32 = 1
        var responseBytes = Data(count: 16)
        responseBytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            base.storeBytes(of: UInt32(16).littleEndian, as: UInt32.self)
            (base + 4).storeBytes(of: MTPContainerType.response.rawValue.littleEndian, as: UInt16.self)
            (base + 6).storeBytes(of: MTPResponseCode.sessionAlreadyOpen.rawValue.littleEndian, as: UInt16.self)
            (base + 8).storeBytes(of: UInt32(0).littleEndian, as: UInt32.self)     // txID
            (base + 12).storeBytes(of: existingSessionID.littleEndian, as: UInt32.self)
        }

        switch MTPResponseContainer.parse(from: responseBytes) {
        case .failure(let err):
            XCTFail("Response parse failed: \(err)")
        case .success(let response):
            XCTAssertEqual(response.responseCode, MTPResponseCode.sessionAlreadyOpen.rawValue)
            XCTAssertEqual(response.parameters.count, 1, "SessionAlreadyOpen must carry 1 parameter")
            XCTAssertEqual(response.parameters.first, existingSessionID,
                           "Parameter[0] should be the existing session ID")
            XCTAssertEqual(response.transactionID, MTPTransactionIDAllocator.openSessionTransactionID)
        }
    }

    /// Verify that a bare OK response (no parameters, 12 bytes) is correctly parsed —
    /// this is what a successful OpenSession returns.
    func testOpenSessionOKResponseParsesCleanly() {
        var responseBytes = Data(count: 12)
        responseBytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            base.storeBytes(of: UInt32(12).littleEndian, as: UInt32.self)
            (base + 4).storeBytes(of: MTPContainerType.response.rawValue.littleEndian, as: UInt16.self)
            (base + 6).storeBytes(of: MTPResponseCode.ok.rawValue.littleEndian, as: UInt16.self)
            (base + 8).storeBytes(of: MTPTransactionIDAllocator.openSessionTransactionID.littleEndian, as: UInt32.self)
        }

        switch MTPResponseContainer.parse(from: responseBytes) {
        case .failure(let err):
            XCTFail("Response parse failed: \(err)")
        case .success(let response):
            XCTAssertTrue(response.isOK)
            XCTAssertTrue(response.parameters.isEmpty, "OK response for OpenSession has no parameters")
            XCTAssertEqual(response.transactionID, MTPTransactionIDAllocator.openSessionTransactionID)
        }
    }

    func testMTPResponseRejectsPartialParameterForSessionAlreadyOpen() {
        var responseBytes = Data(count: 13)
        responseBytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            base.storeBytes(of: UInt32(13).littleEndian, as: UInt32.self)
            (base + 4).storeBytes(of: MTPContainerType.response.rawValue.littleEndian, as: UInt16.self)
            (base + 6).storeBytes(of: MTPResponseCode.sessionAlreadyOpen.rawValue.littleEndian, as: UInt16.self)
            (base + 8).storeBytes(of: MTPTransactionIDAllocator.openSessionTransactionID.littleEndian, as: UInt32.self)
        }

        if case .success = MTPResponseContainer.parse(from: responseBytes) {
            XCTFail("A response with a partial parameter must be rejected")
        }
    }
    func testDataWritesPreserveSingleContainerAcrossTransferBoundaries() throws {
        for size in [0, 1, 65523, 65524, 65525, 65536, 65537, 1048576] {
            let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            var writes: [Data] = []
            try MTPDataPacket.write(code: MTPOperationCode.sendObject.rawValue,
                                    transactionID: 9, payload: payload,
                                    maxTransferSize: 65536, endpointPacketSize: 512) { writes.append($0) }
            XCTAssertFalse(writes.isEmpty)
            XCTAssertTrue(writes.allSatisfy { $0.count <= 65536 })
            XCTAssertTrue(writes.dropLast().allSatisfy { !$0.isEmpty })
            XCTAssertEqual(writes.last!.isEmpty, (size + 12) % 512 == 0)
            let wire = writes.reduce(into: Data()) { $0.append($1) }
            let header = try MTPContainerHeader.parse(from: wire).get()
            XCTAssertEqual(Int(header.containerLength), size + 12)
            XCTAssertEqual(wire.count, size + 12)
            XCTAssertEqual(header.transactionID, 9)
            XCTAssertEqual(header.code, MTPOperationCode.sendObject.rawValue)
            XCTAssertEqual(Data(wire.dropFirst(12)), payload)
            XCTAssertEqual(try MTPDataContainer.parse(from: wire).get().payload, payload)
        }
    }

    func testDataWriteStopsAtFailedUSBChunk() {
        enum TestFailure: Error { case disconnected }
        var attempts = 0
        XCTAssertThrowsError(try MTPDataPacket.write(
            code: MTPOperationCode.sendObject.rawValue, transactionID: 9,
            payload: Data(repeating: 0xA5, count: 200000), maxTransferSize: 65536, endpointPacketSize: 512
        ) { _ in
            attempts += 1
            if attempts == 2 { throw TestFailure.disconnected }
        })
        XCTAssertEqual(attempts, 2)
    }

    func testDataWriteRejectsInvalidChunkSizeWithoutWriting() {
        var attempted = false
        XCTAssertThrowsError(try MTPDataPacket.write(
            code: MTPOperationCode.sendObject.rawValue, transactionID: 9,
            payload: Data(), maxTransferSize: 0, endpointPacketSize: 512
        ) { _ in attempted = true })
        XCTAssertFalse(attempted)
    }

    func testDataWriteTerminatesOnlyExactEndpointBoundaries() throws {
        for packetSize in [512, 1024] {
            for length in [packetSize - 1, packetSize, packetSize + 1, 65536] {
                var writes: [Data] = []
                try MTPDataPacket.write(code: 0x100D, transactionID: 4,
                    payload: Data(repeating: 0xAB, count: length - 12),
                    maxTransferSize: 65536, endpointPacketSize: packetSize) { writes.append($0) }
                XCTAssertEqual(writes.filter { $0.isEmpty }.count, length % packetSize == 0 ? 1 : 0)
                XCTAssertEqual(writes.last!.isEmpty, length % packetSize == 0)
                XCTAssertEqual(writes.reduce(0) { $0 + $1.count }, length)
            }
        }
    }

    // MARK: - Untrusted packet bounds

    private func packetHeader(length: UInt32, type: UInt16 = 2) -> Data {
        var writer = MTPDataWriter()
        writer.writeUInt32(length)
        writer.writeUInt16(type)
        writer.writeUInt16(type == 3 ? 0x2001 : 0x1004)
        writer.writeUInt32(1)
        return writer.bytes
    }

    private func assertMalformed(_ body: () throws -> Void,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let parseError = error as? MTPParseError,
                  case .malformed(let message) = parseError else {
                return XCTFail("Expected typed malformed error, got \(error)", file: file, line: line)
            }
            XCTAssertFalse(message.isEmpty, file: file, line: line)
        }
    }

    func testDataContainerRejectsDeclaredLengthsBelowHeader() {
        for length: UInt32 in [0, 1, 11] {
            assertMalformed { _ = try MTPDataContainer.parse(from: self.packetHeader(length: length)).get() }
        }
    }

    func testDataContainerAcceptsHeaderOnlyAndPreservesTrailingByteBehavior() throws {
        var packet = packetHeader(length: 12)
        XCTAssertTrue(try MTPDataContainer.parse(from: packet).get().payload.isEmpty)
        packet.append(contentsOf: [0xAA, 0xBB])
        // Framing/consumption of trailing containers is a separate transport task.
        XCTAssertTrue(try MTPDataContainer.parse(from: packet).get().payload.isEmpty)
    }

    func testContainerParsersRejectTruncatedHeaders() {
        for size in [0, 1, 11] {
            let packet = Data(repeating: 0, count: size)
            assertMalformed { _ = try MTPContainerHeader.parse(from: packet).get() }
            assertMalformed { _ = try MTPDataContainer.parse(from: packet).get() }
            assertMalformed { _ = try MTPResponseContainer.parse(from: packet).get() }
        }
    }

    func testContainersRejectOversizedDeclaredLengthsWithoutOverflow() {
        for length: UInt32 in [13, 16, 0x80000000, UInt32.max] {
            assertMalformed { _ = try MTPDataContainer.parse(from: self.packetHeader(length: length)).get() }
            assertMalformed { _ = try MTPResponseContainer.parse(from: self.packetHeader(length: length, type: 3)).get() }
        }
    }

    func testArraysRejectTruncatedPayloadBeforeReadingElements() {
        for elementSize in [2, 4] {
            var writer = MTPDataWriter()
            writer.writeUInt32(2)
            var bytes = writer.bytes
            bytes.append(Data(repeating: 0, count: 2 * elementSize - 1))
            var reader = MTPDataReader(data: bytes)
            assertMalformed {
                if elementSize == 2 { _ = try reader.readUInt16Array() }
                else { _ = try reader.readUInt32Array() }
            }
            XCTAssertEqual(reader.offset, 4, "Reject before consuming any array elements")
        }
    }

    func testArraysRejectExtremeCountsWithoutMultiplicationOverflow() {
        // These counts would overflow UInt32 byte-count multiplication for
        // one or both element widths. No huge backing allocation is needed.
        for count: UInt32 in [0x40000000, 0x80000000, UInt32.max] {
            var writer = MTPDataWriter()
            writer.writeUInt32(count)
            writer.writeUInt32(0)
            var reader16 = MTPDataReader(data: writer.bytes)
            var reader32 = MTPDataReader(data: writer.bytes)
            assertMalformed { _ = try reader16.readUInt16Array() }
            assertMalformed { _ = try reader32.readUInt32Array() }
            XCTAssertEqual(reader16.offset, 4)
            XCTAssertEqual(reader32.offset, 4)
        }
    }

    func testArraysAcceptEmptyAndNonemptyPayloads() throws {
        for count in [0, 3] {
            var writer16 = MTPDataWriter()
            var writer32 = MTPDataWriter()
            writer16.writeUInt32(UInt32(count))
            writer32.writeUInt32(UInt32(count))
            for i in 0..<count {
                writer16.writeUInt16(UInt16(i))
                writer32.writeUInt32(UInt32(i))
            }
            var reader16 = MTPDataReader(data: writer16.bytes)
            var reader32 = MTPDataReader(data: writer32.bytes)
            XCTAssertEqual(try reader16.readUInt16Array(), (0..<count).map { UInt16($0) })
            XCTAssertEqual(try reader32.readUInt32Array(), (0..<count).map { UInt32($0) })
            XCTAssertEqual(reader16.bytesRemaining, 0)
            XCTAssertEqual(reader32.bytesRemaining, 0)
        }
    }

    func testResponseRejectsSixParametersAndAcceptsFive() throws {
        for count in [5, 6] {
            var packet = packetHeader(length: UInt32(12 + count * 4), type: 3)
            var writer = MTPDataWriter()
            for i in 0..<count { writer.writeUInt32(UInt32(i)) }
            packet.append(writer.bytes)
            if count == 6 {
                assertMalformed { _ = try MTPResponseContainer.parse(from: packet).get() }
            } else {
                XCTAssertEqual(try MTPResponseContainer.parse(from: packet).get().parameters, [0, 1, 2, 3, 4])
            }
        }
    }

    func testLargeValidHandleArrayHasNoTransportBufferLimit() throws {
        var writer = MTPDataWriter()
        writer.writeUInt32(20_000)
        for handle: UInt32 in 0..<20_000 { writer.writeUInt32(handle) }
        let packet = MTPDataPacket.serialise(code: 0x1007, transactionID: 1, payload: writer.bytes)
        let container = try MTPDataContainer.parse(from: packet).get()
        var reader = MTPDataReader(data: container.payload)
        let handles = try reader.readUInt32Array()
        XCTAssertEqual(handles, Array(UInt32(0)..<20_000))
        XCTAssertEqual(reader.bytesRemaining, 0)
    }

    func testReaderBoundsAtEndAndTruncatedStrings() throws {
        var empty = MTPDataReader(data: Data())
        for read in [
            { _ = try empty.readUInt8() }, { _ = try empty.readUInt16() },
            { _ = try empty.readUInt32() }, { _ = try empty.readUInt64() },
            { _ = try empty.readUInt16Array() }, { _ = try empty.readUInt32Array() }
        ] {
            XCTAssertThrowsError(try read()) { error in
                guard let parseError = error as? MTPParseError,
                      case .insufficientData = parseError else {
                    return XCTFail("Expected insufficientData, got \(error)")
                }
            }
        }
        var string = MTPDataReader(data: Data([255, 0]))
        XCTAssertThrowsError(try string.readMTPString()) { error in
            guard let parseError = error as? MTPParseError,
                  case .insufficientData(needed: 510, available: 1) = parseError else {
                return XCTFail("Expected bounded string-length error, got \(error)")
            }
        }
        XCTAssertEqual(string.offset, 1)
    }

    func testParsersAcceptDataWithNonzeroStartIndex() throws {
        var writer = MTPDataWriter()
        writer.writeUInt8(0xAA)
        writer.writeMTPString("Phone")
        var reader = MTPDataReader(data: writer.bytes.dropFirst())
        XCTAssertEqual(try reader.readMTPString(), "Phone")
        XCTAssertEqual(reader.bytesRemaining, 0)

        var packet = Data([0xAA])
        packet.append(packetHeader(length: 16))
        packet.append(contentsOf: [1, 0, 1, 0])
        let parsed = try MTPDataContainer.parse(from: packet.dropFirst()).get()
        XCTAssertEqual(parsed.payload, Data([1, 0, 1, 0]))
    }

    // Replay captured device bytes through the same parser and array reader used by getStorageIDs.
    func testCapturedStorageIDExchanges() throws {
        let fixtures: [(Data, [UInt32])] = [
            (Data([0x10, 0, 0, 0, 2, 0, 4, 0x10, 2, 0, 0, 0, 0, 0, 0, 0]), []),
            (Data([0x14, 0, 0, 0, 2, 0, 4, 0x10, 2, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0]), [0x10001])
        ]
        let response = try MTPResponseContainer.parse(from:
            Data([0x0C, 0, 0, 0, 3, 0, 1, 0x20, 2, 0, 0, 0])).get()
        XCTAssertTrue(response.isOK)
        XCTAssertEqual(response.transactionID, 2)
        for (raw, expectedIDs) in fixtures {
            let header = try MTPContainerHeader.parse(from: raw).get()
            XCTAssertEqual(Int(header.containerLength), raw.count)
            XCTAssertEqual(header.containerType, 2)
            let container = try MTPDataContainer.parse(from: raw).get()
            XCTAssertEqual(container.operationCode, 0x1004)
            XCTAssertEqual(container.transactionID, response.transactionID)
            XCTAssertEqual(container.payload.count, 4 + expectedIDs.count * 4)
            var reader = MTPDataReader(data: container.payload)
            XCTAssertEqual(try reader.readUInt32Array(), expectedIDs)
            XCTAssertEqual(reader.bytesRemaining, 0)
        }
        // A count of one without its ID must fail, never become an empty array.
        var truncated = MTPDataReader(data: Data([1, 0, 0, 0]))
        XCTAssertThrowsError(try truncated.readUInt32Array())
    }

    func testStorageInfoResponseOnlyInvalidStorageIDPreservesError() throws {
        let raw = Data([0x0C, 0, 0, 0, 3, 0, 8, 0x20, 3, 0, 0, 0])
        let header = try MTPContainerHeader.parse(from: raw).get()
        XCTAssertEqual(header.containerLength, 12)
        XCTAssertEqual(header.containerType, MTPContainerType.response.rawValue)
        let response = try MTPResponseContainer.parse(from: raw).get()
        XCTAssertEqual(response.responseCode, 0x2008)
        XCTAssertEqual(response.transactionID, 3)
        XCTAssertFalse(response.isOK)
        XCTAssertTrue(response.parameters.isEmpty)
        XCTAssertThrowsError(try MTPDataContainer.parse(from: raw).get())
    }

}
