import Foundation
import IOKit
import IOUSBHost
import MTPProbeLib

public enum MTPDeviceError: Error, CustomStringConvertible {
    case failedToCreateInterface
    case pipesNotFound
    case sendCommandFailed(String)
    case receiveDataFailed(String)
    case mtpTransferFailed(
        operationCode: UInt16,
        containerType: UInt16,
        transactionID: UInt32,
        responseCode: UInt16,
        declaredLength: UInt32,
        actualBytes: Int,
        headerHex: String
    )

    public var description: String {
        switch self {
        case .failedToCreateInterface:
            return "Failed to create IOUSBHostInterface"
        case .pipesNotFound:
            return "Bulk IN/OUT pipes not found"
        case .sendCommandFailed(let message):
            return message
        case .receiveDataFailed(let message):
            return message
        case .mtpTransferFailed(let operationCode, let containerType, let transactionID, let responseCode, let declaredLength, let actualBytes, let headerHex):
            return """
            MTP transfer failed
            1. MTP Operation Code: 0x\(String(operationCode, radix: 16, uppercase: true))
            2. Container Type: 0x\(String(containerType, radix: 16, uppercase: true))
            3. Transaction ID: \(transactionID)
            4. MTP Response Code: 0x\(String(responseCode, radix: 16, uppercase: true))
            5. Declared Container Length: \(declaredLength) vs Actual Bytes Received: \(actualBytes)
            6. Raw Packet Header: \(headerHex)
            """
        }
    }
}

public class MTPDevice {
    private let interface: IOUSBHostInterface
    private let bulkInPipe: IOUSBHostPipe
    private let bulkOutPipe: IOUSBHostPipe
    private let bulkOutMaxPacketSize: Int
    private let receiveDecoder = MTPReceiveDecoder(maximumReadSize: MTPBulkMaxPacketSize)
    private let coordinator = MTPSessionCoordinator()

    /// The session ID established by openSession(), or nil if no session is open.
    public var sessionID: UInt32? { coordinator.sessionID }

    /// The current lifecycle state of the MTP session.
    public var sessionState: MTPSessionState { coordinator.sessionState }

    public init(service: io_service_t) throws {
        // Log only allowlisted interface properties; do not dump the complete
        // registry dictionary because it may contain device identifiers.
        var properties: Unmanaged<CFMutableDictionary>?
        let propertiesResult = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        if propertiesResult == kIOReturnSuccess,
           let registryProperties = properties?.takeRetainedValue() as? [String: Any] {
            let safeKeys = [
                "idVendor", "idProduct", "bInterfaceNumber", "bInterfaceClass",
                "bInterfaceSubClass", "bInterfaceProtocol", "USB Interface Number",
                "USB Interface Class", "USB Interface Subclass", "USB Interface Protocol"
            ]
            let summary = safeKeys.compactMap { key in
                registryProperties[key].map { "\(key)=\($0)" }
            }.joined(separator: ", ")
            print("MTP interface service properties: \(summary.isEmpty ? "(no allowlisted properties found)" : summary)")
        } else {
            print("MTP interface service properties unavailable (IORegistry result: \(propertiesResult))")
        }

        // USBDeviceDiscovery matches IOUSBHostInterface objects by MTP class,
        // subclass, and protocol, and the probe passes that service here.
        let intf: IOUSBHostInterface
        do {
            intf = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            let nsError = error as NSError
            print("IOUSBHostInterface initialization error: \(String(describing: error))")
            print("IOUSBHostInterface NSError domain: \(nsError.domain), code: \(nsError.code), description: \(nsError.localizedDescription)")
            throw MTPDeviceError.failedToCreateInterface
        }
        
        self.interface = intf
        
        let confDesc = intf.configurationDescriptor
        let intfDesc = intf.interfaceDescriptor
        var epDesc = IOUSBGetNextEndpointDescriptor(confDesc, intfDesc, nil)
        
        var foundIn: IOUSBHostPipe?
        var foundOut: IOUSBHostPipe?
        var outPacketSize = 0
        
        while let desc = epDesc {
            let addr = IOUSBGetEndpointAddress(desc)
            let dir = IOUSBGetEndpointDirection(desc)
            let type = IOUSBGetEndpointType(desc)
            
            // Raw values from AppleUSBDefinitions.h:
            // Type Bulk = 2
            // Direction In = 1
            // Direction Out = 0
            if type == 2 {
                if dir == 1, foundIn == nil {
                    foundIn = try? intf.copyPipe(withAddress: Int(addr))
                } else if dir == 0, foundOut == nil {
                    foundOut = try? intf.copyPipe(withAddress: Int(addr))
                    outPacketSize = Int(UInt16(littleEndian: desc.pointee.wMaxPacketSize) & 0x07ff)
                }
            }
            
            // Get the next descriptor
            epDesc = IOUSBGetNextEndpointDescriptor(confDesc, intfDesc, UnsafeRawPointer(desc).assumingMemoryBound(to: IOUSBDescriptorHeader.self))
        }
        
        guard let bulkIn = foundIn, let bulkOut = foundOut, outPacketSize > 0 else {
            throw MTPDeviceError.pipesNotFound
        }
        
        self.bulkInPipe = bulkIn
        self.bulkOutPipe = bulkOut
        self.bulkOutMaxPacketSize = outPacketSize
        print("Bulk OUT endpoint packet size: \(outPacketSize)")
        
        print("Successfully created IOUSBHostInterface and located bulk pipes.")
    }
    
    public func openSession(timeout: TimeInterval? = nil) throws {
        try coordinator.openSession(timeout: timeout) { openTxID in
            let sessionID: UInt32 = 1
            let command = MTPCommandContainer(
                code: .openSession,
                transactionID: openTxID,
                parameters: [sessionID]
            )
            print("OpenSession command hex: \(hexDump(command.serialise()))")
            try writeUSBData(command.serialise())
            let response = try readResponse(logLabel: "OpenSession")
            try validate(response: response, transactionID: openTxID)
            if response.isOK {
                print("MTP Session Opened Successfully!")
                return sessionID
            }
            if response.responseCode == MTPResponseCode.sessionAlreadyOpen.rawValue {
                guard response.parameters.count == 1,
                      let existingSessionID = response.parameters.first,
                      existingSessionID != 0 else {
                    throw MTPDeviceError.receiveDataFailed(
                        "SessionAlreadyOpen response must contain one non-zero session ID parameter"
                    )
                }
                throw MTPDeviceError.sendCommandFailed(
                    "SessionAlreadyOpen (session ID: \(existingSessionID)). Reconnect the phone to establish a fresh session; refusing to reuse unknown transaction state."
                )
            }
            throw MTPDeviceError.sendCommandFailed("Failed to open session. Code: 0x\(String(response.responseCode, radix: 16))")
        }
    }
    
    public func closeSession(timeout: TimeInterval? = nil) throws {
        try coordinator.closeSession(timeout: timeout) { scope in
            let transactionID = try scope.allocateTransactionID()
            let container = MTPCommandContainer(code: .closeSession, transactionID: transactionID)
            try writeUSBData(container.serialise())
            let response = try readResponse(logLabel: "CloseSession")
            try validate(response: response, transactionID: transactionID)
            guard response.isOK else {
                throw MTPDeviceError.sendCommandFailed("CloseSession failed: 0x\(String(response.responseCode, radix: 16))")
            }
            try scope.completeTransaction(transactionID)
            print("MTP Session Closed Successfully!")
        }
    }

    public func getDeviceInfo(timeout: TimeInterval? = nil) throws -> MTPDeviceInfo {
        try coordinator.perform(timeout: timeout) { scope in
            let data = try executeCommand(.getDeviceInfo, scope: scope)
            return try MTPDeviceInfo.parse(from: data.payload)
        }
    }
    
    public func getStorageIDs(timeout: TimeInterval? = nil) throws -> [UInt32] {
        try coordinator.perform(timeout: timeout) { scope in
            let data = try executeCommand(.getStorageIDs, scope: scope)
            var reader = MTPDataReader(data: data.payload)
            let ids = try reader.readUInt32Array()
            print("GetStorageIDs parsed storage IDs: \(ids.isEmpty ? "(empty)" : ids.map { "0x\(String($0, radix: 16, uppercase: true))" }.joined(separator: ", "))")
            return ids
        }
    }

    public func getStorageInfo(storageID: UInt32, timeout: TimeInterval? = nil) throws -> MTPStorageInfo {
        try coordinator.perform(timeout: timeout) { scope in
            let data = try executeCommand(.getStorageInfo, parameters: [storageID], scope: scope)
            return try MTPStorageInfo.parse(storageID: storageID, from: data.payload)
        }
    }
    
    /// Explicit investigation only: accepts a caller-supplied historical ID and records response-only errors.
    public func diagnoseStorageInfo(storageID: UInt32, timeout: TimeInterval? = nil) throws -> MTPStorageInfo {
        try coordinator.perform(timeout: timeout) { scope in
            print("GetStorageInfo diagnostic storage ID: 0x\(String(storageID, radix: 16))")
            let data = try executeCommand(.getStorageInfo, parameters: [storageID], scope: scope)
            return try MTPStorageInfo.parse(storageID: storageID, from: data.payload)
        }
    }

    public func getObjectHandles(storageID: UInt32, format: UInt16 = 0, parent: UInt32 = 0xFFFFFFFF, timeout: TimeInterval? = nil) throws -> [UInt32] {
        try coordinator.perform(timeout: timeout) { scope in
            let data = try executeCommand(.getObjectHandles, parameters: [storageID, UInt32(format), parent], scope: scope)
            var reader = MTPDataReader(data: data.payload)
            return try reader.readUInt32Array()
        }
    }
    
    public func getObjectInfo(objectHandle: UInt32, timeout: TimeInterval? = nil) throws -> MTPObjectInfo {
        try coordinator.perform(timeout: timeout) { scope in
            let data = try executeCommand(.getObjectInfo, parameters: [objectHandle], scope: scope)
            return try MTPObjectInfo.parse(objectHandle: objectHandle, from: data.payload)
        }
    }

    /// Stream the GetObject data phase into temporary storage, then require OK.
    /// The existing Data API returns a read-only file mapping, not a heap copy.
    public func getObject(handle: UInt32, timeout: TimeInterval? = nil) throws -> Data {
        try coordinator.perform(timeout: timeout) { scope in
            let txID = try scope.allocateTransactionID()
            let command = MTPCommandContainer(code: .getObject, transactionID: txID, parameters: [handle])
            try writeUSBData(command.serialise())
            let data = try readData(operationCode: MTPOperationCode.getObject.rawValue, transactionID: txID)
            try scope.completeTransaction(txID)
            return data.payload
        }
    }

    /// Send a file's metadata to Android, receive the assigned object handle, then upload raw bytes and verify the resulting metadata.
    public func uploadFile(
        at fileURL: URL,
        storageID: UInt32,
        parentHandle: UInt32 = 0xFFFFFFFF,
        filename: String? = nil,
        format: UInt16 = 0x3000,
        timeout: TimeInterval? = nil
    ) throws -> MTPObjectInfo {
        let fileData = try Data(contentsOf: fileURL)
        let targetName = filename ?? fileURL.lastPathComponent

        return try coordinator.perform(timeout: timeout) { scope in
            let objectHandle = try sendObjectInfoInternal(
                storageID: storageID,
                parentHandle: parentHandle,
                filename: targetName,
                fileSize: UInt64(fileData.count),
                format: format,
                scope: scope
            )

            print("SendObjectInfo: OK")
            print("Object Handle: 0x\(String(objectHandle, radix: 16, uppercase: true))")

            _ = try sendObjectInternal(fileData: fileData, objectHandle: objectHandle, scope: scope)
            print("SendObject: OK")

            let data = try executeCommand(.getObjectInfo, parameters: [objectHandle], scope: scope)
            let objectInfo = try MTPObjectInfo.parse(objectHandle: objectHandle, from: data.payload)
            print("GetObjectInfo: OK")
            guard UInt64(objectInfo.objectCompressedSize) == UInt64(fileData.count) else {
                throw MTPDeviceError.receiveDataFailed("Uploaded object size mismatch: expected \(fileData.count), got \(objectInfo.objectCompressedSize)")
            }
            print("Upload metadata size verified; content verification requires download and SHA-256 comparison")
            return objectInfo
        }
    }

    /// Announce a file's metadata to Android and request a new object handle.
    public func sendObjectInfo(
        storageID: UInt32,
        parentHandle: UInt32,
        filename: String,
        fileSize: UInt64,
        format: UInt16 = 0x3000,
        protectionStatus: UInt16 = 0,
        timeout: TimeInterval? = nil
    ) throws -> UInt32 {
        try coordinator.perform(timeout: timeout) { scope in
            try sendObjectInfoInternal(
                storageID: storageID,
                parentHandle: parentHandle,
                filename: filename,
                fileSize: fileSize,
                format: format,
                protectionStatus: protectionStatus,
                scope: scope
            )
        }
    }

    private func sendObjectInfoInternal(
        storageID: UInt32,
        parentHandle: UInt32,
        filename: String,
        fileSize: UInt64,
        format: UInt16 = 0x3000,
        protectionStatus: UInt16 = 0,
        scope: MTPTransactionScope
    ) throws -> UInt32 {
        let txID = try scope.allocateTransactionID()
        let dataSet = MTPObjectInfoDataset.serialise(
            storageID: storageID,
            parentObject: parentHandle,
            objectFormat: format,
            filename: filename,
            fileSize: fileSize,
            protectionStatus: protectionStatus
        )

        let command = MTPCommandContainer(
            code: .sendObjectInfo,
            transactionID: txID,
            parameters: [storageID, parentHandle]
        )

        try writeUSBData(command.serialise())
        try writeUSBData(MTPDataPacket.serialise(code: MTPOperationCode.sendObjectInfo.rawValue, transactionID: txID, payload: dataSet))

        let response = try readResponse()
        try validate(response: response, transactionID: txID)
        if !response.isOK {
            throw MTPDeviceError.sendCommandFailed("SendObjectInfo failed. Code: 0x\(String(response.responseCode, radix: 16))")
        }

        // SendObjectInfo Response (container type 0x0003) parameters, MTP spec:
        //   [0] StorageID
        //   [1] ParentObjectHandle
        //   [2] ObjectHandle
        // Parameter count is derived from ContainerLength in MTPResponseContainer.parse.
        guard response.parameters.count == 3, response.parameters[2] != 0 else {
            throw MTPDeviceError.receiveDataFailed("SendObjectInfo returned no valid object handle")
        }
        try scope.completeTransaction(txID)
        return response.parameters[2]
    }

    /// Sends a file payload to the phone over the MTP bulk OUT pipe.
    public func sendObject(fileData: Data, objectHandle: UInt32 = 0, timeout: TimeInterval? = nil) throws -> UInt32 {
        try coordinator.perform(timeout: timeout) { scope in
            try sendObjectInternal(fileData: fileData, objectHandle: objectHandle, scope: scope)
        }
    }

    private func sendObjectInternal(fileData: Data, objectHandle: UInt32 = 0, scope: MTPTransactionScope) throws -> UInt32 {
        let txID = try scope.allocateTransactionID()
        let command = MTPCommandContainer(code: .sendObject, transactionID: txID)
        do {
            try writeUSBData(command.serialise())
            print("SendObject command transfer: OK (12 bytes), transaction ID: \(txID)")
        } catch {
            print("SendObject command transfer failed: \(error)")
            throw error
        }

        var offset = 0
        try MTPDataPacket.write(code: MTPOperationCode.sendObject.rawValue,
                                transactionID: txID, payload: fileData,
                                maxTransferSize: MTPBulkMaxPacketSize,
                                endpointPacketSize: bulkOutMaxPacketSize) { packet in
            do {
                try writeUSBData(packet)
                if packet.isEmpty { print("SendObject USB zero-length terminator sent") }
            } catch {
                print("SendObject data transfer failed at container offset \(offset), write \(packet.count) bytes: \(error)")
                throw error
            }
            offset += packet.count
        }
        print("SendObject data container: \(offset) bytes; payload: \(fileData.count) bytes; transaction ID: \(txID)")

        let response: MTPResponseContainer
        do {
            response = try readResponse()
        } catch {
            print("SendObject response read failed after \(offset) container bytes: \(error)")
            throw error
        }
        try validate(response: response, transactionID: txID)
        if !response.isOK {
            throw MTPDeviceError.sendCommandFailed("SendObject failed. Code: 0x\(String(response.responseCode, radix: 16))")
        }

        try scope.completeTransaction(txID)
        return response.parameters.first ?? 0
    }
    
    // MARK: - Private Helpers
    
    private func executeCommand(_ code: MTPOperationCode, parameters: [UInt32] = [], scope: MTPTransactionScope) throws -> MTPDataContainer {
        let txID = try scope.allocateTransactionID()
        let container = MTPCommandContainer(code: code, transactionID: txID, parameters: parameters)
        print("MTP command opcode: 0x\(String(code.rawValue, radix: 16)), transaction ID: \(txID)")
        try writeUSBData(container.serialise())
        let data = try readData(operationCode: code.rawValue, transactionID: txID)
        try scope.completeTransaction(txID)
        return data
    }

    private func validate(dataContainer: MTPDataContainer, operationCode: UInt16, transactionID: UInt32) throws {
        guard dataContainer.operationCode == operationCode else {
            throw MTPDeviceError.receiveDataFailed(
                "Data container opcode mismatch: expected 0x\(String(operationCode, radix: 16, uppercase: true)), got 0x\(String(dataContainer.operationCode, radix: 16, uppercase: true))"
            )
        }
        guard dataContainer.transactionID == transactionID else {
            throw MTPDeviceError.receiveDataFailed(
                "Data container transaction ID mismatch: expected \(transactionID), got \(dataContainer.transactionID)"
            )
        }
    }

    private func validate(response: MTPResponseContainer, transactionID: UInt32) throws {
        guard response.transactionID == transactionID else {
            throw MTPDeviceError.receiveDataFailed(
                "Response transaction ID mismatch: expected \(transactionID), got \(response.transactionID)"
            )
        }
    }

    private func writeUSBData(_ data: Data) throws {
        // IOUSBHost sends a zero-length USB packet when the buffer is nil.
        let mutableData: NSMutableData? = data.isEmpty ? nil : NSMutableData(data: data)
        var transferred: Int = 0

        do {
            try bulkOutPipe.__sendIORequest(with: mutableData, bytesTransferred: &transferred, completionTimeout: 5.0)
            guard transferred == data.count else {
                throw MTPDeviceError.sendCommandFailed("Short USB write: expected \(data.count) bytes, transferred \(transferred)")
            }
        } catch {
            throw MTPDeviceError.sendCommandFailed(error.localizedDescription)
        }
    }
    
    private func readBulkInTransfer() throws -> Data {
        let receiveBuffer = NSMutableData(length: MTPBulkMaxPacketSize)!
        var receivedBytes: Int = 0

        do {
            try bulkInPipe.__sendIORequest(with: receiveBuffer, bytesTransferred: &receivedBytes, completionTimeout: 5.0)
        } catch {
            throw MTPDeviceError.receiveDataFailed(error.localizedDescription)
        }

        return Data(bytes: receiveBuffer.bytes, count: receivedBytes)
    }

    private func hexDump(_ data: Data, limit: Int = 256) -> String {
        if data.isEmpty { return "(empty)" }
        let prefix = data.prefix(limit)
        let hex = prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
        if data.count > limit {
            return hex + " ... (\(data.count - limit) more bytes)"
        }
        return hex
    }

    /// All consumers share one decoder, including metadata and response reads.
    /// No command/session boundary clears unread bytes. A framing/I/O failure
    /// poisons this decoder; recovery requires a new MTPDevice/USB connection.
    private func receiveContainer(operationCode: UInt16? = nil,
                                  transactionID: UInt32? = nil,
                                  responseOnly: Bool = false) throws -> MTPReceivedContainer {
        if receiveDecoder.isFailed {
            coordinator.fail(reason: "MTP receive framing failed")
            throw MTPFramingError.failed
        }
        do {
            return try receiveDecoder.receiveStored(read: { try self.readBulkInTransfer() }, onHeader: { header in
                if let transactionID, header.transactionID != transactionID {
                    throw MTPDeviceError.receiveDataFailed("Container transaction ID mismatch: expected \(transactionID), got \(header.transactionID)")
                }
                if responseOnly && header.containerType != MTPContainerType.response.rawValue {
                    throw MTPParseError.invalidContainerType(header.containerType)
                }
                if header.containerType == MTPContainerType.data.rawValue,
                   let operationCode, header.code != operationCode {
                    throw MTPDeviceError.receiveDataFailed("Data opcode mismatch: expected \(operationCode), got \(header.code)")
                }
            })
        } catch {
            if receiveDecoder.isFailed {
                coordinator.fail(reason: error.localizedDescription)
            }
            throw error
        }
    }

    private func readResponse(logLabel: String? = nil, transactionID: UInt32? = nil) throws -> MTPResponseContainer {
        let received = try receiveContainer(transactionID: transactionID, responseOnly: true)
        if let label = logLabel {
            print("\(label) response header: \(received.header.headerHex)")
        }
        return try received.responseContainer()
    }

    private func readData(operationCode: UInt16, transactionID: UInt32) throws -> MTPDataContainer {
        let received = try receiveContainer(operationCode: operationCode, transactionID: transactionID)
        print("MTP received container header: \(received.header.headerHex); payload bytes: \(received.payload.count)")
        if received.header.containerType == MTPContainerType.response.rawValue {
            let response = try received.responseContainer()
            try validate(response: response, transactionID: transactionID)
            throw MTPDeviceError.mtpTransferFailed(
                operationCode: operationCode, containerType: received.header.containerType,
                transactionID: transactionID, responseCode: response.responseCode,
                declaredLength: received.header.containerLength,
                actualBytes: Int(received.header.containerLength), headerHex: received.header.headerHex)
        }
        let data = try received.dataContainer()
        try validate(dataContainer: data, operationCode: operationCode, transactionID: transactionID)
        let response = try readResponse(transactionID: transactionID)
        try validate(response: response, transactionID: transactionID)
        guard response.isOK else {
            throw MTPDeviceError.mtpTransferFailed(
                operationCode: operationCode, containerType: MTPContainerType.response.rawValue,
                transactionID: transactionID, responseCode: response.responseCode,
                declaredLength: received.header.containerLength,
                actualBytes: Int(received.header.containerLength), headerHex: received.header.headerHex)
        }
        return data
    }
}
