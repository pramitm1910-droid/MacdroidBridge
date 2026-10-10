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
    
    public init(service: io_service_t) throws {
        // Attempt to instantiate the interface from the io_service_t
        guard let intf = try? IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil) else {
            throw MTPDeviceError.failedToCreateInterface
        }
        
        self.interface = intf
        
        let confDesc = intf.configurationDescriptor
        let intfDesc = intf.interfaceDescriptor
        var epDesc = IOUSBGetNextEndpointDescriptor(confDesc, intfDesc, nil)
        
        var foundIn: IOUSBHostPipe?
        var foundOut: IOUSBHostPipe?
        
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
                }
            }
            
            // Get the next descriptor
            epDesc = IOUSBGetNextEndpointDescriptor(confDesc, intfDesc, UnsafeRawPointer(desc).assumingMemoryBound(to: IOUSBDescriptorHeader.self))
        }
        
        guard let bulkIn = foundIn, let bulkOut = foundOut else {
            throw MTPDeviceError.pipesNotFound
        }
        
        self.bulkInPipe = bulkIn
        self.bulkOutPipe = bulkOut
        
        print("Successfully created IOUSBHostInterface and located bulk pipes.")
    }
    
    public func openSession() throws {
        // MTP Session ID typically starts at 1
        let sessionID: UInt32 = 1
        try sendCommand(.openSession, parameters: [sessionID])
        let response = try readResponse()
        if !response.isOK && response.responseCode != MTPResponseCode.sessionAlreadyOpen.rawValue {
            throw MTPDeviceError.sendCommandFailed("Failed to open session. Code: 0x\(String(response.responseCode, radix: 16))")
        }
        print("MTP Session Opened Successfully!")
    }
    
    public func getDeviceInfo() throws -> MTPDeviceInfo {
        try sendCommand(.getDeviceInfo)
        let data = try readData()
        return try MTPDeviceInfo.parse(from: data.payload)
    }
    
    public func getStorageIDs() throws -> [UInt32] {
        try sendCommand(.getStorageIDs)
        let data = try readData()
        var reader = MTPDataReader(data: data.payload)
        return try reader.readUInt32Array()
    }
    
    public func getStorageInfo(storageID: UInt32) throws -> MTPStorageInfo {
        try sendCommand(.getStorageInfo, parameters: [storageID])
        let data = try readData()
        return try MTPStorageInfo.parse(storageID: storageID, from: data.payload)
    }
    
    public func getObjectHandles(storageID: UInt32, format: UInt16 = 0, parent: UInt32 = 0xFFFFFFFF) throws -> [UInt32] {
        try sendCommand(.getObjectHandles, parameters: [storageID, UInt32(format), parent])
        let data = try readData()
        var reader = MTPDataReader(data: data.payload)
        return try reader.readUInt32Array()
    }
    
    public func getObjectInfo(objectHandle: UInt32) throws -> MTPObjectInfo {
        try sendCommand(.getObjectInfo, parameters: [objectHandle])
        let data = try readData()
        return try MTPObjectInfo.parse(objectHandle: objectHandle, from: data.payload)
    }

    /// Issue GetObject (0x1009), assemble the 0x0002 data container across bulk-IN transfers, then require 0x2001 OK.
    public func getObject(handle: UInt32, transactionID: UInt32 = 1) throws -> Data {
        let command = MTPCommandContainer(code: .getObject, transactionID: transactionID, parameters: [handle])
        try writeUSBData(command.serialise())

        let assembled = try readAssembledDataContainer(
            operationCode: MTPOperationCode.getObject.rawValue,
            transactionID: transactionID
        )
        let response = try readResponseCapturingDiagnostics(
            operationCode: MTPOperationCode.getObject.rawValue,
            transactionID: transactionID,
            declaredLength: assembled.declaredLength,
            actualBytes: assembled.raw.count,
            headerHex: assembled.headerHex
        )
        if !response.isOK {
            throw MTPDeviceError.mtpTransferFailed(
                operationCode: MTPOperationCode.getObject.rawValue,
                containerType: MTPContainerType.response.rawValue,
                transactionID: response.transactionID,
                responseCode: response.responseCode,
                declaredLength: assembled.declaredLength,
                actualBytes: assembled.raw.count,
                headerHex: assembled.headerHex
            )
        }
        print("GetObject response: 0x\(String(response.responseCode, radix: 16, uppercase: true))")
        return assembled.payload
    }

    /// Send a file's metadata to Android, receive the assigned object handle, then upload raw bytes and verify the resulting metadata.
    public func uploadFile(
        at fileURL: URL,
        storageID: UInt32,
        parentHandle: UInt32 = 0xFFFFFFFF,
        filename: String? = nil,
        format: UInt16 = 0x3000,
        transactionID: UInt32 = 1
    ) throws -> MTPObjectInfo {
        let fileData = try Data(contentsOf: fileURL)
        let targetName = filename ?? fileURL.lastPathComponent

        let objectHandle = try sendObjectInfo(
            storageID: storageID,
            parentHandle: parentHandle,
            filename: targetName,
            fileSize: UInt64(fileData.count),
            format: format,
            transactionID: transactionID
        )

        print("SendObjectInfo: OK")
        print("Object Handle: 0x\(String(objectHandle, radix: 16, uppercase: true))")

        _ = try sendObject(fileData: fileData, objectHandle: objectHandle, transactionID: transactionID)
        print("SendObject: OK")

        let objectInfo = try getObjectInfo(objectHandle: objectHandle)
        print("GetObjectInfo: OK")
        print("Upload verified successfully")
        return objectInfo
    }

    /// Announce a file's metadata to Android and request a new object handle.
    public func sendObjectInfo(
        storageID: UInt32,
        parentHandle: UInt32,
        filename: String,
        fileSize: UInt64,
        format: UInt16 = 0x3000,
        protectionStatus: UInt16 = 0,
        transactionID: UInt32 = 1
    ) throws -> UInt32 {
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
            transactionID: transactionID,
            parameters: [storageID, parentHandle, UInt32(format), UInt32(protectionStatus), UInt32(fileSize & 0xFFFFFFFF)]
        )

        try writeUSBData(command.serialise())
        try writeUSBData(MTPDataPacket.serialise(code: MTPOperationCode.sendObjectInfo.rawValue, transactionID: transactionID, payload: dataSet))

        let response = try readResponse()
        if !response.isOK {
            throw MTPDeviceError.sendCommandFailed("SendObjectInfo failed. Code: 0x\(String(response.responseCode, radix: 16))")
        }

        // SendObjectInfo Response (container type 0x0003) parameters, MTP spec:
        //   [0] StorageID
        //   [1] ParentObjectHandle
        //   [2] ObjectHandle
        // Parameter count is derived from ContainerLength in MTPResponseContainer.parse.
        guard response.parameters.count >= 3 else {
            return 0
        }
        return response.parameters[2]
    }

    /// Sends a file payload to the phone over the MTP bulk OUT pipe.
    ///
    /// This is the real data-transfer phase of the upload flow:
    /// 1. SendObjectInfo is used to announce metadata and obtain the object handle.
    /// 2. SendObject streams the raw file bytes.
    /// 3. The device replies with a final response container indicating success/failure.
    public func sendObject(fileData: Data, objectHandle: UInt32 = 0, transactionID: UInt32 = 1) throws -> UInt32 {
        let command = MTPCommandContainer(code: .sendObject, transactionID: transactionID, parameters: [objectHandle])
        try writeUSBData(command.serialise())

        let chunkSize = MTPBulkMaxPacketSize
        var offset = 0
        while offset < fileData.count {
            let end = min(offset + chunkSize, fileData.count)
            let dataChunk = fileData.subdata(in: offset..<end)
            let packet = MTPDataPacket.serialise(code: MTPOperationCode.sendObject.rawValue,
                                               transactionID: transactionID,
                                               payload: dataChunk)
            try writeUSBData(packet)
            offset = end
        }

        let response = try readResponse()
        if !response.isOK {
            throw MTPDeviceError.sendCommandFailed("SendObject failed. Code: 0x\(String(response.responseCode, radix: 16))")
        }

        return response.parameters.first ?? 0
    }
    
    // MARK: - Private Helpers
    
    private func sendCommand(_ code: MTPOperationCode, parameters: [UInt32] = []) throws {
        let container = MTPCommandContainer(code: code, transactionID: 1, parameters: parameters)
        let data = container.serialise()
        try writeUSBData(data)
    }

    private func writeUSBData(_ data: Data) throws {
        let mutableData = NSMutableData(data: data)
        var transferred: Int = 0

        do {
            try bulkOutPipe.__sendIORequest(with: mutableData, bytesTransferred: &transferred, completionTimeout: 5.0)
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

    private struct AssembledDataContainer {
        let payload: Data
        let declaredLength: UInt32
        let raw: Data
        let headerHex: String
    }

    private func headerHex(from data: Data) -> String {
        data.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func readAssembledDataContainer(operationCode: UInt16, transactionID: UInt32) throws -> AssembledDataContainer {
        var assembled = Data()
        var declaredLength: UInt32?

        while true {
            let chunk: Data
            do {
                chunk = try readBulkInTransfer()
            } catch {
                throw MTPDeviceError.mtpTransferFailed(
                    operationCode: operationCode,
                    containerType: assembled.count >= 6 ? UInt16(littleEndian: assembled.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self) }) : 0,
                    transactionID: transactionID,
                    responseCode: 0,
                    declaredLength: declaredLength ?? 0,
                    actualBytes: assembled.count,
                    headerHex: headerHex(from: assembled)
                )
            }

            if chunk.isEmpty {
                throw MTPDeviceError.mtpTransferFailed(
                    operationCode: operationCode,
                    containerType: assembled.count >= 6 ? UInt16(littleEndian: assembled.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self) }) : 0,
                    transactionID: transactionID,
                    responseCode: 0,
                    declaredLength: declaredLength ?? 0,
                    actualBytes: assembled.count,
                    headerHex: headerHex(from: assembled)
                )
            }

            assembled.append(chunk)

            guard assembled.count >= 12 else { continue }

            switch MTPContainerHeader.parse(from: assembled) {
            case .failure(let err):
                throw MTPDeviceError.mtpTransferFailed(
                    operationCode: operationCode,
                    containerType: 0,
                    transactionID: transactionID,
                    responseCode: 0,
                    declaredLength: 0,
                    actualBytes: assembled.count,
                    headerHex: headerHex(from: assembled) + " (\(err.description))"
                )
            case .success(let header):
                declaredLength = header.containerLength

                if header.containerType == MTPContainerType.response.rawValue {
                    let responseCode: UInt16
                    switch MTPResponseContainer.parse(from: assembled) {
                    case .success(let response):
                        responseCode = response.responseCode
                    case .failure:
                        responseCode = header.code
                    }
                    throw MTPDeviceError.mtpTransferFailed(
                        operationCode: operationCode,
                        containerType: header.containerType,
                        transactionID: header.transactionID,
                        responseCode: responseCode,
                        declaredLength: header.containerLength,
                        actualBytes: assembled.count,
                        headerHex: header.headerHex
                    )
                }

                if header.containerType != MTPContainerType.data.rawValue {
                    throw MTPDeviceError.mtpTransferFailed(
                        operationCode: operationCode,
                        containerType: header.containerType,
                        transactionID: header.transactionID,
                        responseCode: header.code,
                        declaredLength: header.containerLength,
                        actualBytes: assembled.count,
                        headerHex: header.headerHex
                    )
                }

                if assembled.count >= Int(header.containerLength) {
                    let result = MTPDataContainer.parse(from: assembled)
                    switch result {
                    case .success(let container):
                        return AssembledDataContainer(
                            payload: container.payload,
                            declaredLength: header.containerLength,
                            raw: assembled,
                            headerHex: header.headerHex
                        )
                    case .failure(let err):
                        throw MTPDeviceError.mtpTransferFailed(
                            operationCode: operationCode,
                            containerType: header.containerType,
                            transactionID: header.transactionID,
                            responseCode: 0,
                            declaredLength: header.containerLength,
                            actualBytes: assembled.count,
                            headerHex: header.headerHex + " (\(err.description))"
                        )
                    }
                }
            }
        }
    }

    private func readResponseCapturingDiagnostics(
        operationCode: UInt16,
        transactionID: UInt32,
        declaredLength: UInt32,
        actualBytes: Int,
        headerHex: String
    ) throws -> MTPResponseContainer {
        let receivedData: Data
        do {
            receivedData = try readBulkInTransfer()
        } catch {
            throw MTPDeviceError.mtpTransferFailed(
                operationCode: operationCode,
                containerType: MTPContainerType.response.rawValue,
                transactionID: transactionID,
                responseCode: 0,
                declaredLength: declaredLength,
                actualBytes: actualBytes,
                headerHex: headerHex
            )
        }

        switch MTPResponseContainer.parse(from: receivedData) {
        case .success(let response):
            return response
        case .failure:
            let peek = MTPContainerHeader.parse(from: receivedData)
            throw MTPDeviceError.mtpTransferFailed(
                operationCode: operationCode,
                containerType: (try? peek.get())?.containerType ?? 0,
                transactionID: (try? peek.get())?.transactionID ?? transactionID,
                responseCode: (try? peek.get())?.code ?? 0,
                declaredLength: (try? peek.get())?.containerLength ?? declaredLength,
                actualBytes: receivedData.count,
                headerHex: self.headerHex(from: receivedData)
            )
        }
    }

    private func readResponse() throws -> MTPResponseContainer {
        let receivedData = try readBulkInTransfer()
        let result = MTPResponseContainer.parse(from: receivedData)
        
        switch result {
        case .success(let response):
            return response
        case .failure(let err):
            throw MTPDeviceError.receiveDataFailed(err.description)
        }
    }
    
    private func readData() throws -> MTPDataContainer {
        let receiveBuffer = NSMutableData(length: MTPBulkMaxPacketSize)!
        var receivedBytes: Int = 0
        
        do {
            try bulkInPipe.__sendIORequest(with: receiveBuffer, bytesTransferred: &receivedBytes, completionTimeout: 5.0)
        } catch {
            throw MTPDeviceError.receiveDataFailed(error.localizedDescription)
        }
        
        let receivedData = Data(bytes: receiveBuffer.bytes, count: receivedBytes)
        let result = MTPDataContainer.parse(from: receivedData)
        
        switch result {
        case .success(let dataContainer):
            // After data phase, we must read the response container
            let _ = try readResponse()
            return dataContainer
        case .failure(let err):
            throw MTPDeviceError.receiveDataFailed(err.description)
        }
    }
}
