import Foundation

/// One explicitly requested GetStorageIDs exchange. Container bytes are reconstructed
/// from the validated MTP header and payload, so coalesced bytes belonging to a
/// subsequent transaction are never included in the trace.
public struct MTPStorageIDsDiagnostic {
    public let command: Data
    public let bulkInTransferLengths: [Int]
    public let dataContainer: Data?
    public let responseContainer: Data?
    public let storageArrayPayload: Data?
    public let decodedStorageCount: UInt32?
    public let responseCode: UInt16?

    public var report: String {
        func hex(_ bytes: Data?) -> String {
            bytes?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "(not received)"
        }
        return """
        GetStorageIDs raw exchange:
          Command: \(hex(command))
          Bulk-IN transfer lengths: \(bulkInTransferLengths)
          Data container: \(hex(dataContainer))
          Storage-array payload: \(hex(storageArrayPayload))
          Decoded storage count: \(decodedStorageCount.map(String.init) ?? "(not decoded)")
          Response container: \(hex(responseContainer))
          MTP response code: \(responseCode.map { String(format: "0x%04X", $0) } ?? "(not received)")
        """
    }
}

final class MTPStorageIDsDiagnosticRecorder {
    let command: Data
    var bulkInTransferLengths: [Int] = []
    var dataContainer: Data?
    var responseContainer: Data?
    var storageArrayPayload: Data?
    var decodedStorageCount: UInt32?
    var responseCode: UInt16?

    init(command: Data) { self.command = command }

    func record(_ received: MTPReceivedContainer) {
        var writer = MTPDataWriter()
        writer.writeUInt32(received.header.containerLength)
        writer.writeUInt16(received.header.containerType)
        writer.writeUInt16(received.header.code)
        writer.writeUInt32(received.header.transactionID)
        var bytes = writer.bytes
        bytes.append(received.payload)
        if received.header.containerType == MTPContainerType.data.rawValue {
            dataContainer = bytes
            storageArrayPayload = received.payload
        } else if received.header.containerType == MTPContainerType.response.rawValue {
            responseContainer = bytes
            responseCode = received.header.code
        }
    }

    var snapshot: MTPStorageIDsDiagnostic {
        MTPStorageIDsDiagnostic(
            command: command,
            bulkInTransferLengths: bulkInTransferLengths,
            dataContainer: dataContainer,
            responseContainer: responseContainer,
            storageArrayPayload: storageArrayPayload,
            decodedStorageCount: decodedStorageCount,
            responseCode: responseCode
        )
    }
}
