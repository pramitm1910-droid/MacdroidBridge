/// MTPModels.swift
/// Strongly-typed Swift models for MTP device information, storage, and directory entries.
/// These are populated by parsing MTP data payloads; they are pure value types with no USB dependency.

import Foundation

// MARK: - Device Info

/// Parsed MTP GetDeviceInfo response payload.
/// MTP spec §5.1.1 — GetDeviceInfo dataset layout.
public struct MTPDeviceInfo {
    public let standardVersion: UInt16      // MTP standard version (e.g. 0x0064 = 1.00)
    public let vendorExtensionID: UInt32    // 0x00000006 = MTP
    public let vendorExtensionVersion: UInt16
    public let vendorExtensionDesc: String
    public let functionalMode: UInt16       // 0x0000 = standard
    public let operationsSupported: [UInt16]
    public let eventsSupported: [UInt16]
    public let devicePropertiesSupported: [UInt16]
    public let captureFormats: [UInt16]
    public let playbackFormats: [UInt16]
    public let manufacturer: String
    public let model: String
    public let deviceVersion: String
    public let serialNumber: String

    /// Parse a GetDeviceInfo payload (the bytes after the 12-byte MTP header).
    public static func parse(from data: Data) throws -> MTPDeviceInfo {
        var reader = MTPDataReader(data: data)
        let standardVersion       = try reader.readUInt16()
        let vendorExtensionID     = try reader.readUInt32()
        let vendorExtensionVersion = try reader.readUInt16()
        let vendorExtensionDesc   = try reader.readMTPString()
        let functionalMode        = try reader.readUInt16()
        let operationsSupported   = try reader.readUInt16Array()
        let eventsSupported       = try reader.readUInt16Array()
        let devicePropertiesSupported = try reader.readUInt16Array()
        let captureFormats        = try reader.readUInt16Array()
        let playbackFormats       = try reader.readUInt16Array()
        let manufacturer          = try reader.readMTPString()
        let model                 = try reader.readMTPString()
        let deviceVersion         = try reader.readMTPString()
        let serialNumber          = try reader.readMTPString()

        return MTPDeviceInfo(
            standardVersion: standardVersion,
            vendorExtensionID: vendorExtensionID,
            vendorExtensionVersion: vendorExtensionVersion,
            vendorExtensionDesc: vendorExtensionDesc,
            functionalMode: functionalMode,
            operationsSupported: operationsSupported,
            eventsSupported: eventsSupported,
            devicePropertiesSupported: devicePropertiesSupported,
            captureFormats: captureFormats,
            playbackFormats: playbackFormats,
            manufacturer: manufacturer,
            model: model,
            deviceVersion: deviceVersion,
            serialNumber: serialNumber
        )
    }

    public func supports(operation: MTPOperationCode) -> Bool {
        operationsSupported.contains(operation.rawValue)
    }
}

// MARK: - Storage Info

/// Parsed MTP GetStorageInfo response payload.
/// MTP spec §5.2.5 — StorageInfo dataset.
public struct MTPStorageInfo {
    public let storageID: UInt32
    public let storageType: UInt16
    public let filesystemType: UInt16
    public let accessCapability: UInt16
    public let maxCapacity: UInt64
    public let freeSpaceInBytes: UInt64
    public let freeSpaceInObjects: UInt32
    public let storageDescription: String
    public let volumeIdentifier: String

    /// Parse a GetStorageInfo payload.
    public static func parse(storageID: UInt32, from data: Data) throws -> MTPStorageInfo {
        var reader = MTPDataReader(data: data)
        let storageType        = try reader.readUInt16()
        let filesystemType     = try reader.readUInt16()
        let accessCapability   = try reader.readUInt16()
        let maxCapacity        = try reader.readUInt64()
        let freeSpaceInBytes   = try reader.readUInt64()
        let freeSpaceInObjects = try reader.readUInt32()
        let storageDescription = try reader.readMTPString()
        let volumeIdentifier   = try reader.readMTPString()

        return MTPStorageInfo(
            storageID: storageID,
            storageType: storageType,
            filesystemType: filesystemType,
            accessCapability: accessCapability,
            maxCapacity: maxCapacity,
            freeSpaceInBytes: freeSpaceInBytes,
            freeSpaceInObjects: freeSpaceInObjects,
            storageDescription: storageDescription,
            volumeIdentifier: volumeIdentifier
        )
    }

    /// Display name: prefer storageDescription, fall back to volumeIdentifier.
    public var displayName: String {
        let desc = storageDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { return desc }
        let vol = volumeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vol.isEmpty { return vol }
        return "Storage 0x\(String(storageID, radix: 16, uppercase: true))"
    }

    public var capacityString: String { formatBytes(maxCapacity) }
    public var freeString: String { formatBytes(freeSpaceInBytes) }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 1.0 { return String(format: "%.1f MB", mb) }
        return "\(bytes) bytes"
    }
}

// MARK: - Object Info

/// Parsed MTP GetObjectInfo response payload.
/// MTP spec §5.3.2 — ObjectInfo dataset.
public struct MTPObjectInfo {
    public let objectHandle: UInt32
    public let storageID: UInt32
    public let objectFormat: UInt16
    public let protectionStatus: UInt16
    public let objectCompressedSize: UInt32  // 0xFFFFFFFF means use 64-bit property
    public let thumbFormat: UInt16
    public let thumbCompressedSize: UInt32
    public let thumbPixWidth: UInt32
    public let thumbPixHeight: UInt32
    public let imagePixWidth: UInt32
    public let imagePixHeight: UInt32
    public let imageBitDepth: UInt32
    public let parentObject: UInt32
    public let associationType: UInt16
    public let associationDesc: UInt32
    public let sequenceNumber: UInt32
    public let filename: String
    public let dateCreated: String
    public let dateModified: String
    public let keywords: String

    public var isDirectory: Bool {
        objectFormat == MTPObjectFormat.association.rawValue
    }

    /// Parse a GetObjectInfo payload.
    public static func parse(objectHandle: UInt32, from data: Data) throws -> MTPObjectInfo {
        var reader = MTPDataReader(data: data)
        let storageID           = try reader.readUInt32()
        let objectFormat        = try reader.readUInt16()
        let protectionStatus    = try reader.readUInt16()
        let objectCompressedSize = try reader.readUInt32()
        let thumbFormat         = try reader.readUInt16()
        let thumbCompressedSize = try reader.readUInt32()
        let thumbPixWidth       = try reader.readUInt32()
        let thumbPixHeight      = try reader.readUInt32()
        let imagePixWidth       = try reader.readUInt32()
        let imagePixHeight      = try reader.readUInt32()
        let imageBitDepth       = try reader.readUInt32()
        let parentObject        = try reader.readUInt32()
        let associationType     = try reader.readUInt16()
        let associationDesc     = try reader.readUInt32()
        let sequenceNumber      = try reader.readUInt32()
        let filename            = try reader.readMTPString()
        let dateCreated         = try reader.readMTPString()
        let dateModified        = try reader.readMTPString()
        let keywords            = try reader.readMTPString()

        return MTPObjectInfo(
            objectHandle: objectHandle,
            storageID: storageID,
            objectFormat: objectFormat,
            protectionStatus: protectionStatus,
            objectCompressedSize: objectCompressedSize,
            thumbFormat: thumbFormat,
            thumbCompressedSize: thumbCompressedSize,
            thumbPixWidth: thumbPixWidth,
            thumbPixHeight: thumbPixHeight,
            imagePixWidth: imagePixWidth,
            imagePixHeight: imagePixHeight,
            imageBitDepth: imageBitDepth,
            parentObject: parentObject,
            associationType: associationType,
            associationDesc: associationDesc,
            sequenceNumber: sequenceNumber,
            filename: filename,
            dateCreated: dateCreated,
            dateModified: dateModified,
            keywords: keywords
        )
    }
}
