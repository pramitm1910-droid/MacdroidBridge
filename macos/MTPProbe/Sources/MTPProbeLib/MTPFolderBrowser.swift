import Foundation

/// Injectable session facade; the production adapter delegates all wire work to MTPDevice.
public protocol MTPBrowserSession: AnyObject {
    var disconnected: Bool { get }
    func open() throws
    func close() throws
    func shutdown()
    func storageIDs() throws -> [UInt32]
    func storageInfo(_ id: UInt32) throws -> MTPStorageInfo
    func handles(storage: UInt32, parent: UInt32?) throws -> [UInt32]
    func info(_ handle: UInt32) throws -> MTPObjectInfo
}
public extension MTPBrowserSession { var disconnected: Bool { false } }
public final class MTPDeviceBrowserSession: MTPBrowserSession {
    private let device: MTPDevice
    public init(device: MTPDevice) { self.device = device }
    public var disconnected: Bool { device.isDisconnected }
    public func open() throws { try device.openSession() }
    public func close() throws { try device.closeSession() }
    public func shutdown() { device.shutdown() }
    public func storageIDs() throws -> [UInt32] { try device.getBrowserStorageIDs() }
    public func storageInfo(_ id: UInt32) throws -> MTPStorageInfo { try device.getBrowserStorageInfo(id) }
    public func handles(storage: UInt32, parent: UInt32?) throws -> [UInt32] { try device.getBrowserHandles(storage: storage, parent: parent) }
    public func info(_ handle: UInt32) throws -> MTPObjectInfo { try device.getBrowserInfo(handle) }
}

/// Synchronous, serialized metadata API. Call on a worker queue, read snapshots on any queue.
/// No automatic polling, recursive scanning, content operations or implicit continuation.
public final class MTPFolderBrowser {
    public enum Phase: String, Codable { case loading, completed, partial, failed, cancelled, disconnected }
    public enum Failure: Error { case duplicateRefresh, busy, staleIdentity, invalidStorage, invalidDirectory, invalidMetadata, limitExceeded, noContinuation, interrupted }
    public struct Identity: Hashable, Codable {
        public let generation: UUID
        public let storage: UInt32
        public let handle: UInt32
        public init(generation: UUID, storage: UInt32, handle: UInt32) {
            self.generation = generation; self.storage = storage; self.handle = handle
        }
    }
    public struct Entry: Codable {
        public let id: Identity
        public let parent: UInt32
        public let name: String
        public let directory: Bool
        public let format: UInt16
        public let size: UInt64?
        public var sizeLabel: String { size.map { String($0) + " bytes" } ?? "unknown" }
    }
    public struct Storage: Codable {
        public let generation: UUID
        public let id: UInt32
        public let name: String
        public let type: UInt16
    }
    public struct Location: Equatable, Codable {
        public let generation: UUID
        public let storage: UInt32
        public let handle: UInt32? // nil is root; never sent as all-objects selector 0.
    }
    public struct Continuation: Equatable, Codable {
        public let generation: UUID
        public let listing: UUID
        public let offset: Int
    }
    public struct Snapshot: Codable {
        public var phase: Phase = .disconnected
        public var generation = UUID()
        public var storageState: MTPStorageDiscoveryState = .disconnected
        public var storages: [Storage] = []
        public var directory: Location?
        public var entries: [Entry] = []
        public var total: Int = 0
        public var more: Bool = false
        public var continuation: Continuation?
        public var error: String?
        public var inspected: Int { entries.count }
        /// Minimal presentation for tests/diagnostics. JSON escapes untrusted strings.
        public func presentation() throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var object = try JSONSerialization.jsonObject(with: encoder.encode(self)) as! [String: Any]
            object["storageMessage"] = storageState.message
            object["inspected"] = entries.count
            object["sizeLabels"] = entries.map(\.sizeLabel)
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
    }
    private let monotonicNow: () -> TimeInterval
    private let wallNow: () -> Date
    /// 500 ms duplicate-gesture suppression: reject, never sleep or schedule another request.
    public init(monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                wallNow: @escaping () -> Date = { Date() }) {
        self.monotonicNow = monotonicNow; self.wallNow = wallNow
    }
    private var lastRefresh: TimeInterval?
    private var observations: [MTPStorageRefreshObservation] = []
    public var refreshObservations: [MTPStorageRefreshObservation] { locked { observations } }
    private let work = NSLock()
    private let state = NSLock()
    private var view = Snapshot()
    private var session: MTPBrowserSession?
    private var opened = false
    private var revision: UInt64 = 0
    private var handleList: [UInt32] = []
    private var listing = UUID()
    private var path: [Location] = []
    private var known: [Identity: Entry] = [:]
    private var nameBytes = 0
    private var underlyingError: Error?
    public var snapshot: Snapshot { locked { view } }
    public var lastError: Error? { locked { underlyingError } }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        state.lock(); defer { state.unlock() }; return try body()
    }
    private struct Ticket { let generation: UUID; let revision: UInt64; let session: MTPBrowserSession }
    private func check(_ t: Ticket) throws {
        try locked { guard view.generation == t.generation, revision == t.revision, opened else { throw Failure.interrupted } }
    }
    private func operation(_ body: (Ticket) throws -> Void) throws -> Snapshot {
        guard work.try() else { throw Failure.busy }; defer { work.unlock() }
        let t: Ticket = try locked {
            guard opened, let session else { throw Failure.staleIdentity }
            let t = Ticket(generation: view.generation, revision: revision, session: session)
            view.phase = .loading; view.error = nil; underlyingError = nil
            return t
        }
        do { try body(t); try check(t); return snapshot }
        catch {
            if t.session.disconnected && snapshot.generation == t.generation {
                t.session.shutdown(); invalidate(.disconnected, error: error); throw error
            }
            locked {
                if view.generation == t.generation && revision == t.revision {
                    view.phase = .failed; view.more = false; view.continuation = nil; view.error = String(describing: error); underlyingError = error
                }
            }
            throw error // Preserve the original transport/protocol error, not only a string.
        }
    }
    /// Starts/replaces a session; replacement closes the old session and invalidates every old identity.
    @discardableResult public func start(_ newSession: MTPBrowserSession) throws -> Snapshot {
        guard work.try() else { throw Failure.busy }; defer { work.unlock() }
        let old = locked { (session, opened) }
        do { if old.1 { try old.0?.close() } }
        catch { old.0?.shutdown(); invalidate(.failed, error: error); throw error }
        old.0?.shutdown()
        locked {
            revision &+= 1; view = Snapshot(); view.phase = .loading
            session = newSession; opened = false; lastRefresh = nil; handleList = []; path = []; known = [:]; nameBytes = 0; underlyingError = nil
        }
        let generation = snapshot.generation
        let startRevision = locked { revision }
        do {
            try newSession.open()
            try locked { guard view.generation == generation, revision == startRevision else { throw Failure.interrupted }; opened = true }
            let t = locked { Ticket(generation: generation, revision: revision, session: newSession) }
            let ids = try newSession.storageIDs(); try check(t)
            guard ids.count <= 16, Set(ids).count == ids.count, ids.allSatisfy({$0 != 0 && $0 != 0xFFFFFFFF}) else { throw Failure.invalidStorage }
            var stores: [Storage] = []
            for id in ids {
                try check(t); let info = try newSession.storageInfo(id); try check(t)
                guard info.storageID == id else { throw Failure.invalidStorage }
                stores.append(Storage(generation: generation, id: id, name: info.storageDescription, type: info.storageType))
            }
            try locked { try checkLocked(t); view.storages = stores; view.storageState = ids.isEmpty ? .emptySuccess : .available; view.phase = .completed }
            return snapshot
        } catch {
            // If cancellation already aborted the session, do not attempt to revive it.
            if locked({ opened && view.generation == generation }) { try? newSession.close() }
            newSession.shutdown()
            if snapshot.generation == generation { invalidate(.failed, error: error) }
            throw error
        }
    }
    /// Explicit UI action only. No timer, event callback, navigation or error invokes this method.
    /// Each accepted call sends exactly one GetStorageIDs in the current session; no reopen fallback.
    @discardableResult public func refreshStorage(annotation: String? = nil) throws -> Snapshot {
        guard work.try() else { throw Failure.busy }; defer { work.unlock() }
        let now = monotonicNow()
        let (t, previousIDs): (Ticket, Set<UInt32>) = try locked {
            guard opened, let session else { throw Failure.staleIdentity }
            if let previous = lastRefresh, now - previous < 0.5 { throw Failure.duplicateRefresh }
            lastRefresh = now; revision &+= 1
            let ids = Set(view.storages.map(\.id))
            // Invalidate the old listing even when the returned storage set is unchanged.
            view.phase = .loading; view.error = nil; view.entries = []; view.directory = nil
            view.total = 0; view.more = false; view.continuation = nil; view.storages = []
            known = [:]; handleList = []; path = []; nameBytes = 0; listing = UUID(); underlyingError = nil
            return (Ticket(generation: view.generation, revision: revision, session: session), ids)
        }
        var count: Int?
        var outcome: MTPStorageDiscoveryState = .transportFailure
        var failure: String?
        let stamp = wallNow()
        // Bounded annotation; caller must supply only screen/lock-state observations, not names.
        let note = annotation.map { String(String(decoding: $0.utf8.prefix(512), as: UTF8.self).prefix(128)) }
        defer {
            let observation = MTPStorageRefreshObservation(timestamp: stamp, sessionGeneration: t.generation,
                mechanism: "same-session", result: outcome, returnedStorageCount: count,
                failureCategory: failure, annotation: note)
            locked { observations.append(observation); if observations.count > 64 { observations.removeFirst(observations.count - 64) } }
        }
        do {
            try check(t)
            let ids = try t.session.storageIDs(); count = ids.count; try check(t)
            guard ids.count <= 16, Set(ids).count == ids.count, ids.allSatisfy({$0 != 0 && $0 != 0xFFFFFFFF}) else { throw Failure.invalidStorage }
            var details: [MTPStorageInfo] = []
            for id in ids {
                try check(t); let info = try t.session.storageInfo(id); try check(t)
                guard info.storageID == id else { throw Failure.invalidStorage }; details.append(info)
            }
            outcome = ids.isEmpty ? .emptySuccess : .available
            try locked {
                try checkLocked(t)
                // A changed storage identity set starts a new browsing generation, not a new wire session.
                if Set(ids) != previousIDs { view.generation = UUID() }
                view.storages = details.map { Storage(generation: view.generation, id: $0.storageID, name: $0.storageDescription, type: $0.storageType) }
                view.storageState = outcome; view.phase = .completed
            }
            return snapshot
        } catch {
            let current = snapshot
            outcome = current.phase == .cancelled ? .cancelled : current.phase == .disconnected ? .disconnected : MTPStorageDiscoveryState.classify(error)
            failure = String(describing: type(of: error))
            if current.generation == t.generation {
                // A failed re-query is never retried or reused. Close if possible, then release transport.
                try? t.session.close(); t.session.shutdown(); invalidate(outcome == .disconnected ? .disconnected : .failed, error: error)
                locked { view.storageState = outcome }
            }
            throw error
        }
    }

    /// Registry adapters report pre-session discovery failures through this explicit entry point.
    /// Does not open a session or issue protocol operations.
    public func discoveryFailed(_ error: Error) {
        let previous = locked { session }; previous?.shutdown()
        invalidate(.failed, error: error)
    }

    private func checkLocked(_ t: Ticket) throws {
        guard opened, view.generation == t.generation, revision == t.revision else { throw Failure.interrupted }
    }
    @discardableResult public func root(_ storage: Storage) throws -> Snapshot {
        try operation { t in
            try self.locked {
                guard storage.generation == t.generation, self.view.storages.contains(where: {$0.id == storage.id}) else { throw Failure.invalidStorage }
                self.path = []
            }
            try self.load(Location(generation: t.generation, storage: storage.id, handle: nil), t)
        }
    }
    @discardableResult public func open(_ id: Identity) throws -> Snapshot {
        try operation { t in
            let location: Location = try self.locked {
                guard id.generation == t.generation, let entry = self.known[id], entry.directory,
                      let current = self.view.directory, current.storage == id.storage,
                      entry.parent == (current.handle ?? 0), self.view.entries.contains(where: {$0.id == id}) else { throw Failure.staleIdentity }
                guard self.path.count < 128 else { throw Failure.limitExceeded }
                self.path.append(current)
                return Location(generation: t.generation, storage: id.storage, handle: id.handle)
            }
            try self.load(location, t)
        }
    }
    @discardableResult public func back() throws -> Snapshot {
        try operation { t in
            let location = try self.locked { () throws -> Location in
                guard let parent = self.path.popLast() else { throw Failure.invalidDirectory }; return parent
            }
            try self.load(location, t)
        }
    }
    @discardableResult public func loadMore(_ expected: Continuation? = nil) throws -> Snapshot {
        try operation { t in
            try self.locked { guard self.view.more, self.view.directory != nil,
                expected == nil || expected == self.view.continuation else { throw Failure.noContinuation } }
            try self.batch(t)
        }
    }
    private func load(_ location: Location, _ t: Ticket) throws {
        try check(t)
        try locked { try checkLocked(t); view.directory = location; view.entries = []; view.total = 0; view.more = false; view.continuation = nil; handleList = []; listing = UUID() }
        let handles = try t.session.handles(storage: location.storage, parent: location.handle); try check(t)
        guard handles.count <= 4096, Set(handles).count == handles.count,
              handles.allSatisfy({ $0 != 0 && $0 != 0xFFFFFFFF && $0 != location.handle }) else { throw Failure.invalidMetadata }
        try locked { try checkLocked(t); handleList = handles; view.total = handles.count }
        try batch(t)
    }
    private func batch(_ t: Ticket) throws {
        let (location, pending) = try locked { () throws -> (Location, [UInt32]) in
            try checkLocked(t); guard let location = view.directory else { throw Failure.invalidDirectory }
            return (location, Array(handleList.dropFirst(view.entries.count).prefix(32)))
        }
        for handle in pending {
            try check(t); let info = try t.session.info(handle); try check(t)
            let bytes = info.filename.utf8.count
            guard info.objectHandle == handle, info.storageID == location.storage,
                  info.parentObject == (location.handle ?? 0), !info.filename.isEmpty,
                  info.filename != ".", info.filename != "..", !info.filename.contains("/"),
                  bytes <= 1024, !info.filename.unicodeScalars.contains(where: {CharacterSet.controlCharacters.contains($0)}) else { throw Failure.invalidMetadata }
            let id = Identity(generation: t.generation, storage: location.storage, handle: handle)
            let entry = Entry(id: id, parent: info.parentObject, name: info.filename, directory: info.isDirectory,
                              format: info.objectFormat, size: info.isDirectory || info.objectCompressedSize == 0xFFFFFFFF ? nil : UInt64(info.objectCompressedSize))
            try locked {
                try checkLocked(t)
                if let prior = known[id], prior.parent != entry.parent { throw Failure.invalidMetadata }
                let oldBytes = known[id]?.name.utf8.count ?? 0
                guard known[id] != nil || known.count < 8192, nameBytes - oldBytes + bytes <= 8 * 1024 * 1024 else { throw Failure.limitExceeded }
                nameBytes += bytes - oldBytes; known[id] = entry; view.entries.append(entry)
            }
        }
        try locked {
            try checkLocked(t); view.more = view.entries.count < handleList.count
            view.continuation = view.more ? Continuation(generation: t.generation, listing: listing, offset: view.entries.count) : nil
            view.phase = view.more ? .partial : .completed
        }
    }
    /// Call from an existing event adapter on StoreRemoved/StorageInfoChanged.
    /// No event pipe is opened by this backend. Affected IDs are not usable until fresh discovery.
    public func storageChanged(_ storage: UInt32) {
        locked {
            revision &+= 1
            view.storages.removeAll { $0.id == storage }
            known = known.filter { $0.key.storage != storage }; nameBytes = known.values.reduce(0) {$0 + $1.name.utf8.count}
            if view.directory?.storage == storage {
                view.entries = []; view.directory = nil; view.total = 0; handleList = []; path = []
            }
            view.phase = .failed; view.more = false; view.continuation = nil; view.error = "Storage changed; fresh discovery required"
            underlyingError = Failure.invalidStorage
        }
    }
    public func receiveStorageEvent(code: UInt16, storage: UInt32) {
        if code == 0x4005 || code == 0x400C { storageChanged(storage) }
    }
    private func invalidate(_ phase: Phase, error: Error? = nil) {
        locked {
            revision &+= 1; view = Snapshot(); view.phase = phase; view.error = error.map {String(describing: $0)}
            view.storageState = phase == .cancelled ? .cancelled : phase == .disconnected ? .disconnected : error.map { MTPStorageDiscoveryState.classify($0) } ?? .transportFailure
            opened = false; handleList = []; path = []; known = [:]; nameBytes = 0; underlyingError = error
        }
    }
    /// Cancellation/disconnection aborts transport and invalidates all handles. Start a fresh session afterward.
    public func cancel() { let s = locked {session}; invalidate(.cancelled); s?.shutdown() }
    public func disconnected() { let s = locked {session}; invalidate(.disconnected); s?.shutdown() }
    public func close() throws {
        work.lock(); defer {work.unlock()}
        let old = locked {(session, opened)}
        do {
            if old.1 { try old.0?.close() }
            old.0?.shutdown(); invalidate(.disconnected)
        } catch {
            old.0?.shutdown(); invalidate(.failed, error: error); throw error
        }
    }
    deinit { if opened { try? session?.close() }; session?.shutdown() }
}
