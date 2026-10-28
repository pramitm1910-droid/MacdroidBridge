import Foundation
import MTPMetadataContracts

/// Concrete backend-side source for FSKit metadata. Keep this beside MTPFolderBrowser
/// in the MTP process; an XPC client in FSKit can implement the same metadata contract.
public final class MTPFolderBrowserMetadataSource: MTPMetadataSource {
    private let browser: MTPFolderBrowser
    private var namespace = UUID()
    private var observedGeneration: UUID

    public init(browser: MTPFolderBrowser) {
        self.browser = browser
        observedGeneration = browser.snapshot.generation
    }
    public var snapshot: MTPMetadataSnapshot {
        let value = browser.snapshot
        if value.generation != observedGeneration { observedGeneration = value.generation; namespace = UUID() }
        return Self.convert(value, namespace: namespace)
    }
    public func enter(storage: UInt32, path requestedPath: [MTPMetadataObjectIdentity]) throws -> MTPMetadataSnapshot {
        let before = browser.snapshot
        _ = snapshot
        guard let root = before.storages.first(where: { $0.id == storage }) else { throw MTPFolderBrowser.Failure.invalidStorage }
        _ = try browser.root(root)
        for identity in requestedPath {
            // Re-entering an ancestor resets its cursor. A known child may be in
            // a later batch, so finish that ancestor before opening the child.
            for _ in 0..<128 where browser.snapshot.phase == .partial { _ = try browser.loadMore() }
            guard browser.snapshot.phase == .completed else { throw MTPFolderBrowser.Failure.limitExceeded }
            guard identity.generation == browser.snapshot.generation, identity.storage == storage else { throw MTPFolderBrowser.Failure.staleIdentity }
            _ = try browser.open(MTPFolderBrowser.Identity(generation: identity.generation, storage: identity.storage, handle: identity.handle))
        }
        return snapshot
    }
    public func continueListing() throws -> MTPMetadataSnapshot { _ = try browser.loadMore(); return snapshot }
    public func refresh() throws -> MTPMetadataSnapshot {
        namespace = UUID()
        let refreshed = try browser.refreshStorage(annotation: "Finder metadata refresh")
        observedGeneration = refreshed.generation
        return Self.convert(refreshed, namespace: namespace)
    }
    public func cancel() { browser.cancel() }

    private static func convert(_ source: MTPFolderBrowser.Snapshot, namespace: UUID) -> MTPMetadataSnapshot {
        let state: MTPMetadataSnapshot.State
        switch source.phase {
        case .loading, .partial: state = .partial
        case .completed: state = source.directory == nil && source.storageState == .emptySuccess ? .empty : .complete
        case .failed: state = .failed(source.error ?? "MTP metadata request failed")
        case .cancelled: state = .cancelled
        case .disconnected: state = .disconnected
        }
        let storageState: MTPMetadataStorageState
        switch source.storageState {
        case .available: storageState = .available
        case .emptySuccess: storageState = .emptySuccess
        case .deviceUnavailable: storageState = .deviceUnavailable
        case .transportFailure: storageState = .transportFailure
        case .disconnected: storageState = .disconnected
        case .cancelled: storageState = .cancelled
        }
        return MTPMetadataSnapshot(generation: source.generation, namespace: namespace, state: state,
            storageState: storageState,
            storages: source.storages.map { .init(generation: $0.generation, id: $0.id, name: $0.name) },
            directoryStorage: source.directory?.storage, directoryHandle: source.directory.map { $0.handle ?? 0 },
            entries: source.entries.map { .init(generation: $0.id.generation, storage: $0.id.storage,
                handle: $0.id.handle, parent: $0.parent, name: $0.name, isDirectory: $0.directory,
                size: $0.size, format: $0.format) })
    }
}
