import Foundation

/// Stable identity crossing the MTP/backend boundary. Object handles are valid only
/// for the associated session generation and storage.
public struct MTPMetadataObjectIdentity: Hashable, Codable {
    public let generation: UUID
    public let storage: UInt32
    public let handle: UInt32
    public init(generation: UUID, storage: UInt32, handle: UInt32) {
        self.generation = generation; self.storage = storage; self.handle = handle
    }
}

public enum MTPMetadataStorageState: String, Codable { case available, emptySuccess, deviceUnavailable, transportFailure, disconnected, cancelled }

public struct MTPMetadataSnapshot: Codable {
    public enum State: Codable, Equatable { case available, empty, partial, complete, failed(String), disconnected, cancelled }
    public struct Storage: Codable, Equatable {
        public let generation: UUID
        public let id: UInt32
        public let name: String
        public init(generation: UUID, id: UInt32, name: String) { self.generation = generation; self.id = id; self.name = name }
    }
    public struct Entry: Codable, Equatable {
        public let generation: UUID
        public let storage: UInt32
        public let handle: UInt32
        public let parent: UInt32
        public let name: String
        public let isDirectory: Bool
        public let size: UInt64?
        public let format: UInt16
        public init(generation: UUID, storage: UInt32, handle: UInt32, parent: UInt32,
                    name: String, isDirectory: Bool, size: UInt64?, format: UInt16) {
            self.generation = generation; self.storage = storage; self.handle = handle; self.parent = parent
            self.name = name; self.isDirectory = isDirectory; self.size = size; self.format = format
        }
        public var identity: MTPMetadataObjectIdentity {
            MTPMetadataObjectIdentity(generation: generation, storage: storage, handle: handle)
        }
    }
    public let generation: UUID
    /// Changes on storage refresh even if the MTP session and storage IDs stay the same.
    public let namespace: UUID
    public let state: State
    public let storageState: MTPMetadataStorageState
    public let storages: [Storage]
    public let directoryStorage: UInt32?
    public let directoryHandle: UInt32?
    public let entries: [Entry]
    public init(generation: UUID, namespace: UUID? = nil, state: State, storageState: MTPMetadataStorageState,
                storages: [Storage], directoryStorage: UInt32? = nil,
                directoryHandle: UInt32? = nil, entries: [Entry] = []) {
        self.generation = generation; self.namespace = namespace ?? generation; self.state = state
        self.storageState = storageState; self.storages = storages; self.directoryStorage = directoryStorage
        self.directoryHandle = directoryHandle; self.entries = entries
    }
}

/// Implementations live beside the MTP backend or in an XPC client in the FSKit extension.
/// The contract carries metadata only; it has no file-content or mutation methods.
public protocol MTPMetadataSource: AnyObject {
    var snapshot: MTPMetadataSnapshot { get }
    func enter(storage: UInt32, path: [MTPMetadataObjectIdentity]) throws -> MTPMetadataSnapshot
    func continueListing() throws -> MTPMetadataSnapshot
    func refresh() throws -> MTPMetadataSnapshot
    func cancel()
}

/// A content reference is valid only in one metadata namespace and one MTP session.
/// Providers must revalidate all three object identity fields before touching a device.
public struct MTPContentReference: Hashable, Codable {
    public let identity: MTPMetadataObjectIdentity
    public let namespace: UUID
    public let knownSize: UInt64?
    public init(identity: MTPMetadataObjectIdentity, namespace: UUID, knownSize: UInt64?) {
        self.identity = identity; self.namespace = namespace; self.knownSize = knownSize
    }
}

public struct MTPContentReadRequest: Hashable {
    public static let maximumLength = 1 << 20
    public let reference: MTPContentReference
    public let offset: UInt64
    public let length: Int
    public init(reference: MTPContentReference, offset: Int64, length: Int) throws {
        guard offset >= 0, length > 0, length <= Self.maximumLength,
              let size = reference.knownSize else { throw MTPContentReadError.invalidRequest }
        let start = UInt64(offset)
        guard offset <= Int64.max - Int64(length), start <= UInt64.max - UInt64(length),
              start <= size else { throw MTPContentReadError.invalidRequest }
        self.reference = reference; self.offset = start
        self.length = Int(min(UInt64(length), size - start))
    }
}

public enum MTPContentReadError: Error, Equatable {
    case invalidRequest, staleReference, cancelled, timedOut, disconnected
    case partialTransfer(expected: Int, actual: Int), corrupted(expected: Int, actual: Int)
    case unsupported
}

public enum MTPContentReadResult: Equatable {
    case bytes(Data)
    case endOfFile
}

/// Thread-safe cancellation token passed to an isolated content provider.
public final class MTPContentCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func checkCancellation() throws { if isCancelled { throw MTPContentReadError.cancelled } }
}

/// Deliberately separate from MTPMetadataSource. Metadata-only implementations do
/// not gain file-read capability until a bounded, range-capable backend is verified.
public protocol MTPReadOnlyContentProvider: AnyObject {
    func read(_ request: MTPContentReadRequest, cancellation: MTPContentCancellation) throws -> MTPContentReadResult
}

/// Validates identity before and after provider access, and requires exact range
/// lengths. A provider cannot turn a short transfer into a successful read.
public final class MTPBoundedContentReader {
    private let provider: MTPReadOnlyContentProvider
    private let isCurrent: (MTPContentReference) -> Bool
    public init(provider: MTPReadOnlyContentProvider, isCurrent: @escaping (MTPContentReference) -> Bool) {
        self.provider = provider; self.isCurrent = isCurrent
    }
    public func read(_ request: MTPContentReadRequest, cancellation: MTPContentCancellation) throws -> MTPContentReadResult {
        try cancellation.checkCancellation()
        guard isCurrent(request.reference) else { throw MTPContentReadError.staleReference }
        let result = try provider.read(request, cancellation: cancellation)
        try cancellation.checkCancellation()
        guard isCurrent(request.reference) else { throw MTPContentReadError.staleReference }
        switch result {
        case .endOfFile:
            guard request.reference.knownSize == request.offset else {
                throw MTPContentReadError.corrupted(expected: request.length, actual: 0)
            }
        case .bytes(let bytes):
            guard bytes.count == request.length else {
                throw MTPContentReadError.corrupted(expected: request.length, actual: bytes.count)
            }
        }
        return result
    }
}
