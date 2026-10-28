import Foundation
import Darwin
import MTPMetadataContracts

/// A stable, session-scoped node model for FSKit lookup/enumeration/attributes.
public struct MTPFilesystemNode: Hashable {
    public enum Kind: Hashable { case volumeRoot, storage, directory, file }
    public let fileID: UInt64
    public let parentID: UInt64
    public let generation: UUID
    public let namespace: UUID
    public let storageID: UInt32?
    public let objectHandle: UInt32?
    public let name: String
    public let kind: Kind
    public let size: UInt64?
    public let format: UInt16?
    public var hasKnownSize: Bool { kind != .file || size != nil }
}

/// Converts snapshots into a read-only filesystem namespace. Directory contents are
/// publishable only when complete. Partial snapshots remain queryable as state and
/// can be continued explicitly; they are never mistaken for a complete listing.
public final class MTPMetadataAdapter {
    public enum Failure: Error { case incompleteDirectory, staleNode, unsupportedContent, ambiguousName, busy }
    private let source: MTPMetadataSource
    private let lock = NSRecursiveLock()
    private var ids: [String: UInt64] = [:]
    private var reverseIDs: [UInt64: String] = [:]
    private var nodes: [UInt64: MTPFilesystemNode] = [:]
    private var currentNamespace: UUID
    private var operationActive = false

    public init(source: MTPMetadataSource) {
        self.source = source; self.currentNamespace = source.snapshot.namespace
        let root = MTPFilesystemNode(fileID: 2, parentID: 2, generation: source.snapshot.generation, namespace: currentNamespace,
            storageID: nil, objectHandle: nil, name: "Android", kind: .volumeRoot, size: nil, format: nil)
        nodes[2] = root; ids["root"] = 2; reverseIDs[2] = "root"
    }
    public var isReadOnly: Bool { true }
    public var supportsFileContentReads: Bool { false }
    public var snapshot: MTPMetadataSnapshot { synchronized { synchronizeGeneration(); return source.snapshot } }
    public var root: MTPFilesystemNode { synchronized { synchronizeGeneration(); return nodes[2]! } }

    public func refreshStorage() throws -> MTPMetadataSnapshot { try exclusive { let result = try source.refresh(); synchronizeGeneration(); return result } }
    public func continueListing() throws -> MTPMetadataSnapshot { try exclusive { try source.continueListing() } }
    public func cancel() {
        source.cancel() // Must be able to interrupt a backend call while an operation owns the adapter lock.
        synchronized { clearForGeneration(source.snapshot.namespace) }
    }

    public func children(of node: MTPFilesystemNode) throws -> [MTPFilesystemNode] {
        try exclusive {
            synchronizeGeneration()
            guard nodes[node.fileID] == node else { throw Failure.staleNode }
            let state = source.snapshot
            if node.kind == .volumeRoot {
                switch state.storageState {
                case .emptySuccess: return []
                case .available: break
                case .disconnected: throw posix(ENOTCONN)
                case .cancelled: throw posix(ECANCELED)
                case .deviceUnavailable: throw posix(ENODEV)
                case .transportFailure: throw posix(EIO)
                }
                return try uniqueNames(state.storages.map { storage in
                    let key = "\(state.namespace.uuidString):\(storage.generation.uuidString):\(storage.id):root"
                    return try makeNode(key: key, generation: storage.generation, namespace: state.namespace, storage: storage.id,
                        handle: nil, parent: 2, name: storage.name, kind: .storage, size: nil, format: nil)
                })
            }
            guard let storage = node.storageID else { throw Failure.staleNode }
            let route = route(to: node)
            _ = try source.enter(storage: storage, path: route)
            var listing = source.snapshot
            for _ in 0..<128 where listing.state == .partial { listing = try source.continueListing() }
            switch listing.state {
            case .complete: break
            case .disconnected: throw posix(ENOTCONN)
            case .cancelled: throw posix(ECANCELED)
            case .failed: throw posix(EIO)
            case .empty, .available, .partial: throw Failure.incompleteDirectory
            }
            let expectedParent: UInt32 = route.last?.handle ?? 0
            let validStorage = listing.storages.contains { $0.id == storage && $0.generation == node.generation }
            let validEntries = listing.entries.allSatisfy { entry in
                entry.generation == node.generation && entry.storage == storage && entry.parent == expectedParent
            }
            guard listing.namespace == node.namespace, listing.generation == node.generation,
                  listing.directoryStorage == storage, listing.directoryHandle == expectedParent,
                  validStorage, validEntries else { throw Failure.staleNode }
            return try uniqueNames(listing.entries.map { entry in
                let kind: MTPFilesystemNode.Kind = entry.isDirectory ? .directory : .file
                let key = "\(listing.namespace.uuidString):\(entry.generation.uuidString):\(entry.storage):\(entry.handle)"
                return try makeNode(key: key, generation: entry.generation, namespace: listing.namespace, storage: entry.storage,
                    handle: entry.handle, parent: node.fileID, name: entry.name, kind: kind,
                    size: entry.size, format: entry.format)
            })
        }
    }
    public func lookup(_ name: String, in directory: MTPFilesystemNode) throws -> MTPFilesystemNode {
        if name == "." { return directory }
        if name == ".." { return try node(directory.parentID) }
        let matches = try children(of: directory).filter { $0.name == name }
        guard matches.count == 1 else { throw matches.isEmpty ? posix(ENOENT) : posix(EEXIST) }
        return matches[0]
    }
    public func node(_ fileID: UInt64) throws -> MTPFilesystemNode {
        try synchronized { synchronizeGeneration(); guard let node = nodes[fileID] else { throw posix(ESTALE) }; return node }
    }
    public func attributesSize(of node: MTPFilesystemNode) throws -> UInt64 {
        guard try self.node(node.fileID) == node else { throw posix(ESTALE) }
        guard node.kind != .file || node.size != nil else { throw posix(EOPNOTSUPP) }
        return node.size ?? 0
    }
    public func readContents(of node: MTPFilesystemNode, offset: Int64, length: Int) throws -> Data {
        guard try self.node(node.fileID) == node else { throw posix(ESTALE) }
        throw posix(EOPNOTSUPP)
    }
    public var mutationError: Error { posix(EROFS) }

    private func route(to node: MTPFilesystemNode) -> [MTPMetadataObjectIdentity] {
        guard let storage = node.storageID else { return [] }
        var route: [MTPMetadataObjectIdentity] = []
        var current = node
        while current.kind != .storage {
            guard let handle = current.objectHandle else { break }
            route.insert(MTPMetadataObjectIdentity(generation: current.generation, storage: storage, handle: handle), at: 0)
            guard let parent = nodes[current.parentID] else { break }; current = parent
        }
        return route
    }
    private func uniqueNames(_ values: [MTPFilesystemNode]) throws -> [MTPFilesystemNode] {
        for value in values {
            guard !value.name.isEmpty, value.name != ".", value.name != "..", !value.name.contains("/"),
                  value.name.utf8.count <= 255,
                  !value.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw posix(EINVAL) }
        }
        let groups = Dictionary(grouping: values, by: \.name)
        var used = Set(values.filter { groups[$0.name]!.count == 1 }.map(\.name))
        return try values.map { value in
            guard groups[value.name]!.count > 1 else { return value }
            let discriminator = value.objectHandle.map { String($0, radix: 16) } ?? value.storageID.map { "storage-\(String($0, radix: 16))" } ?? "item-\(value.fileID)"
            let stem = "\(value.name) [MTP-\(discriminator)]"
            var displayed = stem
            var suffix = 2
            while used.contains(displayed) { displayed = "\(stem) (\(suffix))"; suffix += 1 }
            used.insert(displayed)
            return try makeNode(key: "display:\(value.fileID):\(displayed)", generation: value.generation, namespace: value.namespace,
                storage: value.storageID, handle: value.objectHandle, parent: value.parentID,
                name: displayed, kind: value.kind, size: value.size, format: value.format)
        }
    }
    private func makeNode(key: String, generation: UUID, namespace: UUID, storage: UInt32?, handle: UInt32?, parent: UInt64,
                          name: String, kind: MTPFilesystemNode.Kind, size: UInt64?, format: UInt16?) throws -> MTPFilesystemNode {
        let id: UInt64
        if let existing = ids[key] { id = existing }
        else {
            var hash: UInt64 = 14695981039346656037
            for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
            id = hash < 3 ? hash + 3 : hash
            guard reverseIDs[id] == nil || reverseIDs[id] == key else { throw posix(EOVERFLOW) }
            ids[key] = id; reverseIDs[id] = key
        }
        let node = MTPFilesystemNode(fileID: id, parentID: parent, generation: generation, namespace: namespace,
            storageID: storage, objectHandle: handle, name: name, kind: kind, size: size, format: format)
        nodes[id] = node
        return node
    }
    private func synchronizeGeneration() {
        let namespace = source.snapshot.namespace
        if namespace != currentNamespace { clearForGeneration(namespace) }
    }
    private func clearForGeneration(_ namespace: UUID) {
        currentNamespace = namespace; ids = ["root": 2]; reverseIDs = [2: "root"]; nodes = [:]
        let generation = source.snapshot.generation
        nodes[2] = MTPFilesystemNode(fileID: 2, parentID: 2, generation: generation, namespace: namespace,
            storageID: nil, objectHandle: nil, name: "Android", kind: .volumeRoot, size: nil, format: nil)
    }
    private func synchronized<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    private func exclusive<T>(_ body: () throws -> T) throws -> T {
        guard lock.try() else { throw Failure.busy }; defer { lock.unlock() }
        guard !operationActive else { throw Failure.busy }; operationActive = true; defer { operationActive = false }
        return try body()
    }
}

