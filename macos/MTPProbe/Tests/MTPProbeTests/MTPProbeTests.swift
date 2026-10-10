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
}
