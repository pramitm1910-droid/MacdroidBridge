import Foundation

/// Versioned metadata-only wire contract. No content or mutation operations exist.
public enum MTPIPCOperation: String, Codable { case initialize, storages, directory, nextPage, refresh, cancel, disconnect }
public enum MTPIPCError: String, Error, Codable {
    case malformed, unsupportedVersion, disconnected, cancelled, staleSession, staleNamespace
    case staleIdentity, staleResponse, unavailable, sourceFailure, invalidSequence, busy
}
public struct MTPIPCRequest: Codable {
    public var version = 1
    public var id = UUID()
    public var sequence: UInt64 = 0
    public var session: UUID?
    public var namespace: UUID?
    public var generation: UUID?
    public var operation: MTPIPCOperation
    public var storage: UInt32?
    public var path: [MTPMetadataObjectIdentity] = []
    public init(operation: MTPIPCOperation) { self.operation = operation }
}
public struct MTPIPCResponse: Codable {
    public var version = 1
    public var id: UUID
    public var sequence: UInt64
    public var session: UUID
    public var snapshot: MTPMetadataSnapshot?
    public var error: MTPIPCError?
}

/// A future NSXPC transport can carry these Data envelopes. exchange must terminate
/// on cancellation/disconnection. This milestone supplies only an in-process transport.
public protocol MTPMetadataTransport: AnyObject {
    func exchange(_ data: Data) throws -> Data
    func invalidate(session: UUID, cancelled: Bool)
}

/// One attached metadata source and one client session per service. Source calls are
/// serialized because MTPMetadataSource owns a mutable directory cursor. cancel()
/// must be thread-safe, as required by the existing metadata adapter contract.
public final class MTPMetadataService {
    private let operations = NSLock()
    private let admission: DispatchSemaphore
    private let state = NSLock()
    private var source: MTPMetadataSource?
    private var session = UUID()
    private var lastSequence: UInt64 = 0
    private var knownDirectories: Set<MTPMetadataObjectIdentity> = []
    private var routes: [MTPMetadataObjectIdentity: [MTPMetadataObjectIdentity]] = [:]

    /// Includes the active operation; overflow fails immediately, never queues unbounded work.
    public init(source: MTPMetadataSource? = nil, maximumPending: Int = 8) {
        precondition(maximumPending > 0 && maximumPending <= 64)
        self.source = source; admission = DispatchSemaphore(value: maximumPending)
    }
    /// Restart/reattach invalidates old in-flight replies before exposing a new source.
    public func attach(_ replacement: MTPMetadataSource?) {
        state.lock()
        let old = source
        source = replacement; session = UUID(); lastSequence = 0
        state.unlock()
        old?.cancel()
    }
    public func invalidate(session: UUID, cancelled: Bool) {
        state.lock()
        guard self.session == session else { state.unlock(); return }
        let old = source
        source = nil; self.session = UUID(); lastSequence = 0
        state.unlock()
        old?.cancel()
    }
    public func receive(_ data: Data) throws -> Data {
        let request: MTPIPCRequest
        do { request = try JSONDecoder().decode(MTPIPCRequest.self, from: data) }
        catch { throw MTPIPCError.malformed }
        if request.operation == .cancel || request.operation == .disconnect {
            guard request.version == 1, let session = request.session else { throw MTPIPCError.malformed }
            invalidate(session: session, cancelled: request.operation == .cancel)
            return try JSONEncoder().encode(MTPIPCResponse(id: request.id, sequence: request.sequence,
                session: session, error: request.operation == .cancel ? .cancelled : .disconnected))
        }
        guard admission.wait(timeout: .now()) == .success else { throw MTPIPCError.busy }
        defer { admission.signal() }
        operations.lock(); defer { operations.unlock() }
        state.lock()
        let active = source
        let ticket = session
        state.unlock()
        var response = MTPIPCResponse(id: request.id, sequence: request.sequence, session: ticket)
        do {
            guard request.version == 1 else { throw MTPIPCError.unsupportedVersion }
            guard let active else { throw MTPIPCError.disconnected }
            if request.operation == .initialize {
                guard request.session == nil, request.sequence == 0 else { throw MTPIPCError.invalidSequence }
                // Every handshake establishes a new epoch, also rejecting replayed replies.
                state.lock()
                guard session == ticket, source === active else { state.unlock(); throw MTPIPCError.staleSession }
                session = UUID(); lastSequence = 0; response.session = session; state.unlock()
                knownDirectories.removeAll(); routes.removeAll()
            } else {
                guard request.session == ticket else { throw MTPIPCError.staleSession }
                state.lock()
                let valid = session == ticket && source === active && request.sequence > lastSequence
                if valid { lastSequence = request.sequence }
                state.unlock()
                guard valid else { throw MTPIPCError.invalidSequence }
                guard request.generation == active.snapshot.generation else { throw MTPIPCError.staleSession }
                guard request.namespace == active.snapshot.namespace else { throw MTPIPCError.staleNamespace }
            }
            let before = active.snapshot
            let result: MTPMetadataSnapshot
            switch request.operation {
            case .cancel, .disconnect: throw MTPIPCError.malformed // Handled before the operation lock.
            case .initialize, .storages: result = before
            case .refresh:
                result = try active.refresh()
                knownDirectories.removeAll(); routes.removeAll()
            case .directory:
                guard before.storageState == .available else { throw MTPIPCError.unavailable }
                guard let storage = request.storage,
                      before.storages.contains(where: { $0.id == storage && $0.generation == before.generation }) else {
                    throw MTPIPCError.staleIdentity
                }
                for (index, identity) in request.path.enumerated() {
                    guard identity.generation == before.generation, identity.storage == storage,
                          knownDirectories.contains(identity), routes[identity] == Array(request.path.prefix(index)) else {
                        throw MTPIPCError.staleIdentity
                    }
                }
                result = try active.enter(storage: storage, path: request.path)
            case .nextPage:
                guard before.state == .partial, before.storageState == .available else { throw MTPIPCError.unavailable }
                guard before.storages.contains(where: { $0.id == before.directoryStorage && $0.generation == before.generation }) else { throw MTPIPCError.staleIdentity }
                result = try active.continueListing()
            }
            state.lock(); let current = session == response.session && source === active; state.unlock()
            guard current else { throw MTPIPCError.staleSession }
            if request.operation != .refresh && request.operation != .initialize {
                guard result.generation == before.generation else { throw MTPIPCError.staleSession }
                guard result.namespace == before.namespace else { throw MTPIPCError.staleNamespace }
            }
            guard result.storages.allSatisfy({ $0.generation == result.generation }) else { throw MTPIPCError.staleIdentity }
            if request.operation == .directory || request.operation == .nextPage {
                let storage = request.operation == .directory ? request.storage : before.directoryStorage
                let parent = request.operation == .directory ? (request.path.last?.handle ?? 0) : before.directoryHandle
                guard result.directoryStorage == storage, result.directoryHandle == parent,
                      result.entries.allSatisfy({ $0.generation == result.generation && $0.storage == storage && $0.parent == parent }) else {
                    throw MTPIPCError.staleIdentity
                }
                if result.state == .complete {
                    let parentRoute: [MTPMetadataObjectIdentity]
                    if request.operation == .directory { parentRoute = request.path }
                    else if let parent, parent != 0, let storage {
                        let identity = MTPMetadataObjectIdentity(generation: result.generation, storage: storage, handle: parent)
                        parentRoute = (routes[identity] ?? []) + [identity]
                    } else { parentRoute = [] }
                    // A complete relisting revokes previously learned descendants.
                    let obsolete = knownDirectories.filter { identity in
                        guard identity.storage == storage, let route = routes[identity] else { return false }
                        return route.starts(with: parentRoute)
                    }
                    for identity in obsolete { knownDirectories.remove(identity); routes.removeValue(forKey: identity) }
                    for entry in result.entries where entry.isDirectory {
                        knownDirectories.insert(entry.identity); routes[entry.identity] = parentRoute
                    }
                }
            }
            // Preserve partial/unavailable states and nil sizes verbatim, never upgrade them.
            response.snapshot = result
        } catch let error as MTPIPCError { response.error = error }
          catch is CancellationError { response.error = .cancelled }
          catch { response.error = .sourceFailure }
        return try JSONEncoder().encode(response)
    }
}

/// Synthetic byte serialization boundary only: no listener, process, USB or registration.
public final class MTPInProcessMetadataTransport: MTPMetadataTransport {
    private let service: MTPMetadataService
    private let lock = NSLock()
    private var invalidated = false
    public init(service: MTPMetadataService) { self.service = service }
    public func exchange(_ data: Data) throws -> Data {
        lock.lock(); let closed = invalidated; lock.unlock()
        guard !closed else { throw MTPIPCError.disconnected }
        let reply = try service.receive(data)
        lock.lock(); let ended = invalidated; lock.unlock()
        guard !ended else { throw MTPIPCError.disconnected }
        return reply
    }
    public func invalidate(session: UUID, cancelled: Bool) {
        lock.lock(); invalidated = true; lock.unlock()
        var request = MTPIPCRequest(operation: cancelled ? .cancel : .disconnect)
        request.session = session
        if let data = try? JSONEncoder().encode(request) { _ = try? service.receive(data) }
    }
}

/// Synchronous facade for the existing adapter. Concurrent callers serialize so a
/// response cannot overwrite a newer directory cursor. Cancellation bypasses that lock.
public final class MTPMetadataClient: MTPMetadataSource {
    private let transport: MTPMetadataTransport
    private let operations = NSLock()
    private let state = NSLock()
    private var value: MTPMetadataSnapshot
    private var session: UUID
    private var sequence: UInt64 = 0
    private var terminal: MTPIPCError?

    public init(transport: MTPMetadataTransport) throws {
        self.transport = transport
        let request = MTPIPCRequest(operation: .initialize)
        let response = try JSONDecoder().decode(MTPIPCResponse.self, from: transport.exchange(JSONEncoder().encode(request)))
        guard response.version == 1, response.id == request.id, response.sequence == 0 else { throw MTPIPCError.staleResponse }
        if let error = response.error { throw error }
        guard let snapshot = response.snapshot else { throw MTPIPCError.malformed }
        value = snapshot; session = response.session
    }
    public var snapshot: MTPMetadataSnapshot { state.lock(); defer { state.unlock() }; return value }
    public func enter(storage: UInt32, path: [MTPMetadataObjectIdentity]) throws -> MTPMetadataSnapshot {
        try perform(.directory, storage: storage, path: path)
    }
    public func continueListing() throws -> MTPMetadataSnapshot { try perform(.nextPage) }
    public func refresh() throws -> MTPMetadataSnapshot { try perform(.refresh) }
    public func enumerateStorages() throws -> MTPMetadataSnapshot { try perform(.storages) }
    public func cancel() { end(.cancelled) }
    public func disconnect() { end(.disconnected) }
    private func end(_ error: MTPIPCError) {
        state.lock()
        terminal = error
        value = .init(generation: value.generation, namespace: UUID(),
            state: error == .cancelled ? .cancelled : .disconnected,
            storageState: error == .cancelled ? .cancelled : .disconnected, storages: [])
        state.unlock()
        transport.invalidate(session: session, cancelled: error == .cancelled)
    }
    private func perform(_ operation: MTPIPCOperation, storage: UInt32? = nil,
                         path: [MTPMetadataObjectIdentity] = []) throws -> MTPMetadataSnapshot {
        operations.lock(); defer { operations.unlock() }
        state.lock()
        if let terminal { state.unlock(); throw terminal }
        sequence += 1
        var request = MTPIPCRequest(operation: operation)
        request.session = session; request.sequence = sequence
        request.namespace = value.namespace; request.generation = value.generation
        request.storage = storage; request.path = path
        state.unlock()
        do {
            let response = try JSONDecoder().decode(MTPIPCResponse.self, from: transport.exchange(JSONEncoder().encode(request)))
            state.lock(); defer { state.unlock() }
            if let terminal { throw terminal }
            guard response.version == 1, response.id == request.id, response.sequence == request.sequence,
                  response.session == session else { throw MTPIPCError.staleResponse }
            if let error = response.error { throw error }
            guard let snapshot = response.snapshot else { throw MTPIPCError.malformed }
            if operation != .refresh {
                guard snapshot.generation == request.generation, snapshot.namespace == request.namespace else { throw MTPIPCError.staleResponse }
            }
            value = snapshot
            return snapshot
        } catch {
            state.lock(); let ended = terminal; state.unlock()
            if let ended { throw ended }
            // Fail closed; the adapter must not retain cached roots after transport failure.
            end(.disconnected)
            throw error
        }
    }
}
