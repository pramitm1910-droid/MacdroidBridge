/// MTPPacket.swift
/// Structures for constructing and parsing MTP command/response/data containers.
///
/// MTP Container layout (USB bulk transfer, little-endian):
///
///   Offset  Size  Field
///   0       4     ContainerLength  (total bytes including this header)
///   4       2     ContainerType    (command=0x0001, data=0x0002, response=0x0003)
///   6       2     Code             (OperationCode or ResponseCode)
///   8       4     TransactionID
///   12      N     Parameters       (0–5 × UInt32, present only in command/response)
///                                  OR payload data (in data containers)
///
/// Reference: MTP Specification rev 1.1, §2.3.

import Foundation

// MARK: - MTP Command Container

/// Parsed 12-byte MTP container header (little-endian).
public struct MTPContainerHeader {
    public let containerLength: UInt32
    public let containerType: UInt16
    public let code: UInt16
    public let transactionID: UInt32

    public static func parse(from data: Data) -> Result<MTPContainerHeader, MTPParseError> {
        guard data.count >= 12 else {
            return .failure(.malformed("Container header too short: \(data.count) bytes (minimum 12)"))
        }
        return data.withUnsafeBytes { raw -> Result<MTPContainerHeader, MTPParseError> in
            guard let base = raw.baseAddress else {
                return .failure(.malformed("Nil base pointer in container header"))
            }
            let containerLength = UInt32(littleEndian: base.loadUnaligned(as: UInt32.self))
            let containerType = UInt16(littleEndian: (base + 4).loadUnaligned(as: UInt16.self))
            let code = UInt16(littleEndian: (base + 6).loadUnaligned(as: UInt16.self))
            let transactionID = UInt32(littleEndian: (base + 8).loadUnaligned(as: UInt32.self))
            return .success(MTPContainerHeader(
                containerLength: containerLength,
                containerType: containerType,
                code: code,
                transactionID: transactionID
            ))
        }
    }

    public var headerHex: String {
        var bytes = Data(count: 12)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            base.storeBytes(of: containerLength.littleEndian, as: UInt32.self)
            (base + 4).storeBytes(of: containerType.littleEndian, as: UInt16.self)
            (base + 6).storeBytes(of: code.littleEndian, as: UInt16.self)
            (base + 8).storeBytes(of: transactionID.littleEndian, as: UInt32.self)
        }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// A serialisable MTP command container.
public struct MTPCommandContainer {
    public let code: MTPOperationCode
    public let transactionID: UInt32
    public let parameters: [UInt32]  // 0–5 parameters

    public init(code: MTPOperationCode, transactionID: UInt32, parameters: [UInt32] = []) {
        precondition(parameters.count <= 5, "MTP allows at most 5 command parameters")
        self.code = code
        self.transactionID = transactionID
        self.parameters = parameters
    }

    /// Serialise to bytes for transmission over USB bulk-OUT.
    public func serialise() -> Data {
        // Header = 12 bytes, each parameter = 4 bytes
        let payloadLength = parameters.count * 4
        let totalLength = 12 + payloadLength
        var data = Data(count: totalLength)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            // ContainerLength
            base.storeBytes(of: UInt32(totalLength).littleEndian, as: UInt32.self)
            // ContainerType = command (0x0001)
            (base + 4).storeBytes(of: MTPContainerType.command.rawValue.littleEndian, as: UInt16.self)
            // Code
            (base + 6).storeBytes(of: code.rawValue.littleEndian, as: UInt16.self)
            // TransactionID
            (base + 8).storeBytes(of: transactionID.littleEndian, as: UInt32.self)
            // Parameters
            for (i, param) in parameters.enumerated() {
                (base + 12 + i * 4).storeBytes(of: param.littleEndian, as: UInt32.self)
            }
        }
        return data
    }
}

// MARK: - MTP Response Container

/// A parsed MTP response container received over USB bulk-IN.
public struct MTPResponseContainer {
    public let responseCode: UInt16
    public let transactionID: UInt32
    public let parameters: [UInt32]  // 0–5 parameters

    public var isOK: Bool { responseCode == MTPResponseCode.ok.rawValue }

    /// Attempt to parse a raw response container from received bytes.
    /// Returns nil and an error string if the data is malformed.
    public static func parse(from data: Data) -> Result<MTPResponseContainer, MTPParseError> {
        guard data.count >= 12 else {
            return .failure(.malformed("Response too short: \(data.count) bytes (minimum 12)"))
        }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Result<MTPResponseContainer, MTPParseError> in
            guard let base = raw.baseAddress else {
                return .failure(.malformed("Nil base pointer in response data"))
            }
            let containerLength = UInt32(littleEndian: base.loadUnaligned(as: UInt32.self))
            let containerType = UInt16(littleEndian: (base + 4).loadUnaligned(as: UInt16.self))
            let code = UInt16(littleEndian: (base + 6).loadUnaligned(as: UInt16.self))
            let txID = UInt32(littleEndian: (base + 8).loadUnaligned(as: UInt32.self))

            guard containerType == MTPContainerType.response.rawValue else {
                return .failure(.malformed("Expected response container (0x0003), got 0x\(String(containerType, radix: 16))"))
            }
            guard containerLength <= data.count else {
                return .failure(.malformed("ContainerLength (\(containerLength)) exceeds data size (\(data.count))"))
            }

            let paramByteCount = Int(containerLength) - 12
            let paramCount = paramByteCount / 4
            var params: [UInt32] = []
            for i in 0..<paramCount {
                let param = UInt32(littleEndian: (base + 12 + i * 4).loadUnaligned(as: UInt32.self))
                params.append(param)
            }
            return .success(MTPResponseContainer(responseCode: code, transactionID: txID, parameters: params))
        }
    }
}

// MARK: - MTP Data Container

/// A parsed MTP data container (bulk-IN payload following a command).
public struct MTPDataContainer {
    public let operationCode: UInt16
    public let transactionID: UInt32
    /// Raw payload bytes (everything after the 12-byte header).
    public let payload: Data

    /// Attempt to parse a data container from received bytes.
    public static func parse(from data: Data) -> Result<MTPDataContainer, MTPParseError> {
        guard data.count >= 12 else {
            return .failure(.malformed("Data container too short: \(data.count) bytes"))
        }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Result<MTPDataContainer, MTPParseError> in
            guard let base = raw.baseAddress else {
                return .failure(.malformed("Nil base pointer in data container"))
            }
            let containerLength = UInt32(littleEndian: base.loadUnaligned(as: UInt32.self))
            let containerType = UInt16(littleEndian: (base + 4).loadUnaligned(as: UInt16.self))
            let opCode = UInt16(littleEndian: (base + 6).loadUnaligned(as: UInt16.self))
            let txID = UInt32(littleEndian: (base + 8).loadUnaligned(as: UInt32.self))

            guard containerType == MTPContainerType.data.rawValue else {
                return .failure(.malformed("Expected data container (0x0002), got 0x\(String(containerType, radix: 16))"))
            }
            guard Int(containerLength) <= data.count else {
                return .failure(.malformed("ContainerLength (\(containerLength)) exceeds data size (\(data.count))"))
            }

            let payloadStart = 12
            let payloadEnd = Int(containerLength)
            let payload = data.subdata(in: payloadStart..<payloadEnd)
            return .success(MTPDataContainer(operationCode: opCode, transactionID: txID, payload: payload))
        }
    }
}

public enum MTPDataPacket {
    public static func serialise(code: UInt16, transactionID: UInt32, payload: Data) -> Data {
        let totalLength = 12 + payload.count
        var data = Data(count: totalLength)

        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            base.storeBytes(of: UInt32(totalLength).littleEndian, as: UInt32.self)
            (base + 4).storeBytes(of: MTPContainerType.data.rawValue.littleEndian, as: UInt16.self)
            (base + 6).storeBytes(of: code.littleEndian, as: UInt16.self)
            (base + 8).storeBytes(of: transactionID.littleEndian, as: UInt32.self)

            if !payload.isEmpty {
                payload.copyBytes(to: UnsafeMutableRawBufferPointer(start: base + 12, count: payload.count), count: payload.count)
            }
        }

        return data
    }
}

// MARK: - MTP Data Reader

/// A cursor-based reader for parsing MTP data payloads.
/// MTP payloads are always little-endian.
public struct MTPDataReader {
    private let data: Data
    private(set) public var offset: Int = 0

    public init(data: Data) {
        self.data = data
    }

    public var bytesRemaining: Int { data.count - offset }

    public mutating func readUInt8() throws -> UInt8 {
        guard offset + 1 <= data.count else { throw MTPParseError.insufficientData(needed: 1, available: bytesRemaining) }
        let value = data[offset]
        offset += 1
        return value
    }

    public mutating func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw MTPParseError.insufficientData(needed: 2, available: bytesRemaining) }
        let value = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt16 in
            UInt16(littleEndian: (raw.baseAddress! + offset).loadUnaligned(as: UInt16.self))
        }
        offset += 2
        return value
    }

    public mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw MTPParseError.insufficientData(needed: 4, available: bytesRemaining) }
        let value = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            UInt32(littleEndian: (raw.baseAddress! + offset).loadUnaligned(as: UInt32.self))
        }
        offset += 4
        return value
    }

    public mutating func readUInt64() throws -> UInt64 {
        guard offset + 8 <= data.count else { throw MTPParseError.insufficientData(needed: 8, available: bytesRemaining) }
        let value = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt64 in
            UInt64(littleEndian: (raw.baseAddress! + offset).loadUnaligned(as: UInt64.self))
        }
        offset += 8
        return value
    }

    /// Read a MTP Unicode string.
    /// Format: 1-byte length (character count including NUL), then length × UTF-16LE code units.
    /// If length is 0, returns an empty string.
    public mutating func readMTPString() throws -> String {
        let charCount = Int(try readUInt8())
        guard charCount > 0 else { return "" }
        let byteCount = charCount * 2  // UTF-16LE
        guard offset + byteCount <= data.count else {
            throw MTPParseError.insufficientData(needed: byteCount, available: bytesRemaining)
        }
        let stringData = data.subdata(in: offset..<(offset + byteCount))
        offset += byteCount
        // charCount includes trailing NUL — strip it
        let str = String(data: stringData, encoding: .utf16LittleEndian) ?? ""
        return str.trimmingCharacters(in: ["\0"])
    }

    /// Read a MTP Array of UInt32 values.
    /// Format: 4-byte count, then count × UInt32.
    public mutating func readUInt32Array() throws -> [UInt32] {
        let count = Int(try readUInt32())
        var result: [UInt32] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try readUInt32())
        }
        return result
    }

    /// Read a MTP Array of UInt16 values.
    /// Format: 4-byte count, then count × UInt16.
    public mutating func readUInt16Array() throws -> [UInt16] {
        let count = Int(try readUInt32())
        var result: [UInt16] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try readUInt16())
        }
        return result
    }
}

// MARK: - MTP Data Writer

public struct MTPDataWriter {
    private var data = Data()

    public init() {}

    public var bytes: Data { data }

    public mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    public mutating func writeUInt16(_ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    public mutating func writeUInt32(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    public mutating func writeUInt64(_ value: UInt64) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    public mutating func writeMTPString(_ value: String) {
        let utf16 = Array(value.utf16)
        let count = UInt8(utf16.count + 1)
        writeUInt8(count)
        for codeUnit in utf16 {
            writeUInt16(codeUnit)
        }
        writeUInt16(0)
    }
}

public enum MTPObjectInfoDataset {
    public static func serialise(
        storageID: UInt32,
        parentObject: UInt32,
        objectFormat: UInt16,
        filename: String,
        fileSize: UInt64,
        protectionStatus: UInt16 = 0,
        createdDate: String = "2024-01-01T00:00:00",
        modifiedDate: String = "2024-01-01T00:00:00"
    ) -> Data {
        var writer = MTPDataWriter()
        writer.writeUInt32(storageID)
        writer.writeUInt16(objectFormat)
        writer.writeUInt16(protectionStatus)
        writer.writeUInt32(UInt32(fileSize & 0xFFFFFFFF))
        writer.writeUInt16(0)
        writer.writeUInt32(0)
        writer.writeUInt32(0)
        writer.writeUInt32(0)
        writer.writeUInt32(0)
        writer.writeUInt32(0)
        writer.writeUInt32(0)
        writer.writeUInt32(parentObject)
        writer.writeUInt16(0)
        writer.writeUInt32(0)
        writer.writeUInt32(0)
        writer.writeMTPString(filename)
        writer.writeMTPString(createdDate)
        writer.writeMTPString(modifiedDate)
        writer.writeMTPString("")
        return writer.bytes
    }
}

// MARK: - Parse Errors

public enum MTPParseError: Error, CustomStringConvertible {
    case insufficientData(needed: Int, available: Int)
    case invalidContainerType(UInt16)
    case unexpectedResponseCode(UInt16)
    case emptyPayload
    case malformed(String)

    public var description: String {
        switch self {
        case .insufficientData(let needed, let available):
            return "Insufficient data: needed \(needed) bytes, only \(available) available"
        case .invalidContainerType(let type):
            return "Invalid MTP container type: 0x\(String(type, radix: 16, uppercase: true))"
        case .unexpectedResponseCode(let code):
            return "Unexpected MTP response code: 0x\(String(code, radix: 16, uppercase: true))"
        case .emptyPayload:
            return "MTP data container payload was empty"
        case .malformed(let msg):
            return "Malformed data: \(msg)"
        }
    }
}
