import Foundation

public enum MTPFramingError: Error, CustomStringConvertible {
    case failed
    case truncated(remaining: Int)
    case emptyTransfer
    case oversizedRead(Int)

    public var description: String {
        switch self {
        case .failed: return "Receive framing failed; establish a fresh connection before resetting"
        case .truncated(let remaining): return "Truncated MTP stream: expected at least \(remaining) more bytes"
        case .emptyTransfer: return "Unexpected zero-length USB transfer inside or before an MTP container"
        case .oversizedRead(let count): return "USB reader exceeded its bounded read size: \(count) bytes"
        }
    }
}

/// One synchronous decoder per USB connection. Not thread-safe or reentrant.
/// A read supplies bytes, nil means EOF, and empty Data means a USB ZLP.
/// Only a 12-byte header and one bounded read are retained, regardless of the
/// declared payload size. Payload sinks must consume chunks synchronously.
public final class MTPReceiveDecoder {
    public let maximumReadSize: Int
    private var pending = Data()
    private var offset = 0
    private var boundaryZLPAllowed = false
    public private(set) var isFailed = false
    public private(set) var peakBufferedByteCount = 0
    public var unreadByteCount: Int { pending.count - offset }

    public init(maximumReadSize: Int = 65_536) {
        precondition(maximumReadSize > 0 && maximumReadSize <= Int.max - 12)
        self.maximumReadSize = maximumReadSize
    }

    /// Explicitly abandons buffered bytes. Only use after the underlying stream
    /// has also been replaced/reset; never between commands on a live stream.
    public func reset() {
        pending = Data()
        offset = 0
        boundaryZLPAllowed = false
        isFailed = false
        peakBufferedByteCount = 0
    }

    public func invalidate() { isFailed = true }

    @discardableResult
    public func receive(read: () throws -> Data?,
                        onHeader: (MTPContainerHeader) throws -> Void = { _ in },
                        onPayload: (Data) throws -> Void) throws -> MTPContainerHeader {
        guard !isFailed else { throw MTPFramingError.failed }
        do {
            var bytes = Data()
            var allowZLP = boundaryZLPAllowed
            boundaryZLPAllowed = false
            while bytes.count < 12 {
                try refill(read: read, remaining: 12 - bytes.count,
                           allowZLP: &allowZLP)
                let count = min(12 - bytes.count, unreadByteCount)
                bytes.append(take(count))
                allowZLP = false
                peakBufferedByteCount = max(peakBufferedByteCount, pending.count + bytes.count)
            }
            let header = try MTPContainerHeader.parse(from: bytes).get()
            guard header.containerLength >= 12,
                  let length = Int(exactly: header.containerLength) else {
                throw MTPParseError.malformed("Invalid container length \(header.containerLength)")
            }
            // This decoder serves bulk-IN data/response phases, not the event pipe.
            switch header.containerType {
            case MTPContainerType.data.rawValue: break
            case MTPContainerType.response.rawValue:
                guard length <= 32, (length - 12).isMultiple(of: 4) else {
                    throw MTPParseError.malformed("Response must have zero to five complete parameters")
                }
            default: throw MTPParseError.invalidContainerType(header.containerType)
            }
            try onHeader(header) // Validate expected opcode/transaction before payload I/O.
            var remaining = length - 12
            while remaining > 0 {
                var noZLP = false
                try refill(read: read, remaining: remaining, allowZLP: &noZLP)
                let count = min(remaining, unreadByteCount)
                try onPayload(take(count))
                remaining -= count
            }
            // Some USB reads expose the data-phase short-packet terminator
            // separately. Accept at most one ZLP at this exact boundary.
            boundaryZLPAllowed = header.containerType == MTPContainerType.data.rawValue
            return header
        } catch {
            isFailed = true // No resynchronization, retries, or discarded suffixes.
            throw error
        }
    }

    private func refill(read: () throws -> Data?, remaining: Int,
                        allowZLP: inout Bool) throws {
        guard unreadByteCount == 0 else { return }
        pending = Data()
        offset = 0
        while true {
            guard let bytes = try read() else { throw MTPFramingError.truncated(remaining: remaining) }
            guard bytes.count <= maximumReadSize else { throw MTPFramingError.oversizedRead(bytes.count) }
            if bytes.isEmpty {
                guard allowZLP else { throw MTPFramingError.emptyTransfer }
                allowZLP = false
                continue
            }
            pending = bytes
            peakBufferedByteCount = max(peakBufferedByteCount, pending.count)
            return
        }
    }

    private func take(_ count: Int) -> Data {
        let start = pending.index(pending.startIndex, offsetBy: offset)
        let end = pending.index(start, offsetBy: count)
        offset += count // count <= unreadByteCount, so this cannot overflow.
        return pending.subdata(in: start..<end)
    }

    /// Compatibility path for existing Data-returning APIs. Data containers are
    /// spooled, then mapped read-only; no allocation based on their declared size.
    /// Disk usage grows only with received bytes. Partial spools are removed on
    /// failure. The mapping retains the unlinked file until the Data is released.
    public func receiveStored(read: () throws -> Data?,
                              onHeader: (MTPContainerHeader) throws -> Void = { _ in }) throws -> MTPReceivedContainer {
        var directory: URL?
        var file: URL?
        var handle: FileHandle?
        var smallPayload = Data()
        defer {
            try? handle?.close()
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
        do {
            let header = try receive(read: read, onHeader: { header in
                try onHeader(header)
                if header.containerType == MTPContainerType.data.rawValue && header.containerLength > 12 {
                    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mtp-receive-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    directory = root
                    let url = root.appendingPathComponent("payload")
                    guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                         attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    file = url
                    handle = try FileHandle(forWritingTo: url)
                }
            }, onPayload: { chunk in
                if let handle { try handle.write(contentsOf: chunk) }
                else { smallPayload.append(chunk) } // At most 20 response bytes.
            })
            try handle?.close()
            handle = nil
            let payload = try file.map { try Data(contentsOf: $0, options: .alwaysMapped) } ?? smallPayload
            return MTPReceivedContainer(header: header, payload: payload)
        } catch {
            invalidate()
            throw error
        }
    }
}

public struct MTPReceivedContainer {
    public let header: MTPContainerHeader
    public let payload: Data

    public func dataContainer() throws -> MTPDataContainer {
        guard header.containerType == MTPContainerType.data.rawValue else {
            throw MTPParseError.invalidContainerType(header.containerType)
        }
        // Framing has already checked the header and consumed exactly its payload.
        return MTPDataContainer(operationCode: header.code, transactionID: header.transactionID, payload: payload)
    }

    public func responseContainer() throws -> MTPResponseContainer {
        guard header.containerType == MTPContainerType.response.rawValue else {
            throw MTPParseError.invalidContainerType(header.containerType)
        }
        var writer = MTPDataWriter()
        writer.writeUInt32(header.containerLength)
        writer.writeUInt16(header.containerType)
        writer.writeUInt16(header.code)
        writer.writeUInt32(header.transactionID)
        var bytes = writer.bytes
        bytes.append(payload)
        return try MTPResponseContainer.parse(from: bytes).get()
    }
}
