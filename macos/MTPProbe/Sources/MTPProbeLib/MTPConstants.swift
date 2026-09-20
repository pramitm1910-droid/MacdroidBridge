/// MTPConstants.swift
/// All MTP operation codes, response codes, object format codes, and property codes
/// used in this probe. Values are taken verbatim from the MTP specification (rev 1.1).
/// No code generated — all are literal constants from the spec.

// MARK: - MTP Operation Codes (OC)

public enum MTPOperationCode: UInt16 {
    case getDeviceInfo      = 0x1001
    case openSession        = 0x1002
    case closeSession       = 0x1003
    case getStorageIDs      = 0x1004
    case getStorageInfo     = 0x1005
    case sendObjectInfo     = 0x100C
    case getObjectHandles   = 0x1007
    case getObjectInfo      = 0x1008
    case sendObject         = 0x100D
}

// MARK: - MTP Response Codes (RC)

public enum MTPResponseCode: UInt16 {
    case ok                     = 0x2001
    case generalError           = 0x2002
    case sessionNotOpen         = 0x2003
    case invalidTransactionID   = 0x2004
    case operationNotSupported  = 0x2005
    case parameterNotSupported  = 0x2006
    case incompleteTrasfer      = 0x2007
    case invalidStorageID       = 0x2008
    case invalidObjectHandle    = 0x2009
    case deviceBusy             = 0x2019
    case invalidParameter       = 0x201D
    case sessionAlreadyOpen     = 0x201E
    case transactionCancelled   = 0x201F
    case specificationByFormatUnsupported = 0x2014
}

// MARK: - MTP Container Types

public enum MTPContainerType: UInt16 {
    case undefined  = 0x0000
    case command    = 0x0001
    case data       = 0x0002
    case response   = 0x0003
    case event      = 0x0004
}

// MARK: - MTP Object Format Codes (relevant subset)

public enum MTPObjectFormat: UInt16 {
    case association    = 0x3001  // Directory / folder
    case undefined      = 0x3000
}

// MARK: - MTP Storage Types

public enum MTPStorageType: UInt16 {
    case undefined          = 0x0000
    case fixedROM           = 0x0001
    case removableROM       = 0x0002
    case fixedRAM           = 0x0003
    case removableRAM       = 0x0004
}

// MARK: - MTP Access Capability

public enum MTPAccessCapability: UInt16 {
    case readWrite              = 0x0000
    case readOnlyWithoutDeletion = 0x0001
    case readOnlyWithDeletion   = 0x0002
}

// MARK: - Sentinel Object Handle Values

public enum MTPObjectHandleSentinel: UInt32 {
    case root   = 0xFFFFFFFF  // "all objects" or root directory
    case none   = 0x00000000  // Invalid / no parent
}

// MARK: - USB MTP Bulk Packet Size

/// Maximum single MTP bulk packet payload.
/// MTP spec recommends 512 bytes minimum; we use 64 KB to match common device behaviour.
public let MTPBulkMaxPacketSize: Int = 65_536
