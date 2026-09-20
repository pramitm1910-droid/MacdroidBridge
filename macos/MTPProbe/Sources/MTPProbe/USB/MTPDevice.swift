import Foundation
import IOKit
import IOUSBHost
import MTPProbeLib

public enum MTPDeviceError: Error {
    case failedToCreateInterface
    case pipesNotFound
    case sendCommandFailed(String)
    case receiveDataFailed(String)
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
    
    private func readResponse() throws -> MTPResponseContainer {
        let receiveBuffer = NSMutableData(length: MTPBulkMaxPacketSize)!
        var receivedBytes: Int = 0
        
        do {
            try bulkInPipe.__sendIORequest(with: receiveBuffer, bytesTransferred: &receivedBytes, completionTimeout: 5.0)
        } catch {
            throw MTPDeviceError.receiveDataFailed(error.localizedDescription)
        }
        
        let receivedData = Data(bytes: receiveBuffer.bytes, count: receivedBytes)
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
