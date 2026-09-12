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
    
    // MARK: - Private Helpers
    
    private func sendCommand(_ code: MTPOperationCode, parameters: [UInt32] = []) throws {
        let container = MTPCommandContainer(code: code, transactionID: 1, parameters: parameters)
        let data = container.serialise()
        
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
