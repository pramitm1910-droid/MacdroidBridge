import XCTest
import FSKit
import MTPMetadataContracts
@testable import HelloFS

private final class FixtureSource: MTPMetadataSource {
    private(set) var value: MTPMetadataSnapshot
    private var directories: [UInt32: [MTPMetadataSnapshot.Entry]]
    private var requestedPath: [MTPMetadataObjectIdentity] = []
    var partialOnce = false
    var holdPartial = false
    var entered: [[MTPMetadataObjectIdentity]] = []
    var cancelled = false
    func replace(_ snapshot: MTPMetadataSnapshot) { value = snapshot }

    init(generation: UUID = UUID(), namespace: UUID? = nil,
         storages: [MTPMetadataSnapshot.Storage]? = nil,
         root: [MTPMetadataSnapshot.Entry] = [], children: [UInt32: [MTPMetadataSnapshot.Entry]] = [:],
         state: MTPMetadataSnapshot.State = .available,
         storageState: MTPMetadataStorageState = .available) {
        let stores = storages ?? [.init(generation: generation, id: 77, name: "Phone")]
        self.value = .init(generation: generation, namespace: namespace, state: state,
            storageState: storageState, storages: stores)
        self.directories = [0: root].merging(children) { _, new in new }
    }
    var snapshot: MTPMetadataSnapshot { value }
    func enter(storage: UInt32, path: [MTPMetadataObjectIdentity]) throws -> MTPMetadataSnapshot {
        requestedPath = path; entered.append(path)
        let parent = path.last?.handle ?? 0
        let entries = directories[parent] ?? []
        value = .init(generation: value.generation, namespace: value.namespace,
            state: partialOnce || holdPartial ? .partial : .complete, storageState: .available,
            storages: value.storages, directoryStorage: storage, directoryHandle: parent, entries: entries)
        return value
    }
    func continueListing() throws -> MTPMetadataSnapshot {
        if holdPartial { return value }
        partialOnce = false
        value = .init(generation: value.generation, namespace: value.namespace, state: .complete,
            storageState: .available, storages: value.storages, directoryStorage: value.directoryStorage,
            directoryHandle: value.directoryHandle, entries: value.entries)
        return value
    }
    func refresh() throws -> MTPMetadataSnapshot {
        value = .init(generation: value.generation, namespace: UUID(), state: .available,
            storageState: .available, storages: value.storages)
        return value
    }
    func cancel() {
        cancelled = true
        value = .init(generation: value.generation, namespace: UUID(), state: .cancelled,
            storageState: .cancelled, storages: [])
    }
}

final class MTPMetadataAdapterTests: XCTestCase {
    private let generation = UUID(uuidString: "A16C91A6-1B75-44E3-A6D7-2DD5A7EAA510")!
    private func entry(_ handle: UInt32, _ name: String, _ directory: Bool = false,
                       _ size: UInt64? = 4, parent: UInt32 = 0) -> MTPMetadataSnapshot.Entry {
        .init(generation: generation, storage: 77, handle: handle, parent: parent,
              name: name, isDirectory: directory, size: size, format: directory ? 0x3001 : 0x3000)
    }
    private func fixture(root: [MTPMetadataSnapshot.Entry] = [], children: [UInt32: [MTPMetadataSnapshot.Entry]] = [:]) -> (FixtureSource, MTPMetadataAdapter) {
        let source = FixtureSource(generation: generation, root: root, children: children)
        return (source, MTPMetadataAdapter(source: source))
    }
    private func assertPOSIX(_ code: Int32, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain, file: file, line: line)
            XCTAssertEqual((error as NSError).code, Int(code), file: file, line: line)
        }
    }

    func testStorageRootAndCompleteListing() throws {
        let (_, adapter) = fixture(root: [entry(10, "Pictures", true), entry(11, "notes.txt")])
        let stores = try adapter.children(of: adapter.root)
        XCTAssertEqual(stores.map(\.name), ["Phone"])
        let contents = try adapter.children(of: stores[0])
        XCTAssertEqual(contents.map(\.name), ["Pictures", "notes.txt"])
        XCTAssertEqual(contents.map(\.kind), [.directory, .file])
        XCTAssertTrue(adapter.isReadOnly); XCTAssertFalse(adapter.supportsFileContentReads)
    }

    func testPartialListingNeverPublishedAsCompleteAndCanContinue() throws {
        let (source, adapter) = fixture(root: [entry(10, "one"), entry(11, "two")])
        source.partialOnce = true
        let storage = try XCTUnwrap(adapter.children(of: adapter.root).first)
        XCTAssertEqual(source.snapshot.state, .available)
        // The FS-facing call completes the source's explicit bounded continuation before publishing.
        XCTAssertEqual(try adapter.children(of: storage).count, 2)
        XCTAssertEqual(source.entered.count, 1)
    }

    func testPersistentPartialListingIsNotPublished() throws {
        let (source, adapter) = fixture(root: [entry(10, "one")])
        source.holdPartial = true
        let storage = try XCTUnwrap(adapter.children(of: adapter.root).first)
        XCTAssertThrowsError(try adapter.children(of: storage)) { error in
            XCTAssertTrue(error is MTPMetadataAdapter.Failure)
        }
        XCTAssertEqual(source.snapshot.state, .partial)
    }

    func testChildNavigationUsesImmediateGenerationScopedIdentity() throws {
        let child = entry(20, "Album", true)
        let grandchild = entry(21, "photo.jpg", parent: 20)
        let (source, adapter) = fixture(root: [child], children: [20: [grandchild]])
        let storage = try XCTUnwrap(adapter.children(of: adapter.root).first)
        let album = try XCTUnwrap(adapter.children(of: storage).first)
        XCTAssertEqual(try adapter.children(of: album).map(\.name), ["photo.jpg"])
        XCTAssertEqual(source.entered.last?.map(\.handle), [20])
    }

    func testDuplicateNamesReceiveDeterministicHandleSuffixesAndLookupIsUnique() throws {
        let (_, adapter) = fixture(root: [entry(11, "same.txt"), entry(12, "same.txt"), entry(13, "same.txt [MTP-b]")])
        let storage = try XCTUnwrap(adapter.children(of: adapter.root).first)
        let values = try adapter.children(of: storage)
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(Set(values.map(\.name)).count, 3)
        XCTAssertTrue(values[0].name.hasPrefix("same.txt [MTP-"))
        XCTAssertEqual(Set(values.map(\.fileID)).count, 3)
        XCTAssertEqual(try adapter.lookup(values[0].name, in: storage), values[0])
    }

    func testUnicodeNamePreserved() throws {
        let (_, adapter) = fixture(root: [entry(10, "旅行 📷.jpg")])
        let storage = try XCTUnwrap(adapter.children(of: adapter.root).first)
        XCTAssertEqual(try adapter.children(of: storage).first?.name, "旅行 📷.jpg")
    }

    func testUnknownSizeIsNotZeroAndContentReadUnsupported() throws {
        let (_, adapter) = fixture(root: [entry(10, "unknown.bin", false, nil)])
        let storage = try XCTUnwrap(adapter.children(of: adapter.root).first)
        let file = try XCTUnwrap(adapter.children(of: storage).first)
        XCTAssertNil(file.size); XCTAssertFalse(file.hasKnownSize)
        assertPOSIX(EOPNOTSUPP) { _ = try adapter.attributesSize(of: file) }
        assertPOSIX(EOPNOTSUPP) { _ = try adapter.readContents(of: file, offset: 0, length: 1) }
    }

    func testEmptyStorageAndUnavailableStorage() throws {
        let empty = FixtureSource(generation: generation, storages: [], state: .empty,
                                  storageState: .emptySuccess)
        let emptyAdapter = MTPMetadataAdapter(source: empty)
        XCTAssertTrue(try emptyAdapter.children(of: emptyAdapter.root).isEmpty)
        let unavailable = FixtureSource(generation: generation, storages: [], state: .failed("unavailable"),
                                        storageState: .transportFailure)
        let adapter = MTPMetadataAdapter(source: unavailable)
        assertPOSIX(EIO) { _ = try adapter.children(of: adapter.root) }
    }

    func testStableIdentityWithinSessionAndStaleAfterSessionReplacement() throws {
        let (source, adapter) = fixture(root: [entry(10, "file")])
        let storage = try XCTUnwrap(adapter.children(of: adapter.root).first)
        let file = try XCTUnwrap(adapter.children(of: storage).first)
        XCTAssertEqual(try adapter.children(of: storage).first?.fileID, file.fileID)
        source.replace(.init(generation: UUID(), state: .available, storageState: .available,
                             storages: [.init(generation: UUID(), id: 77, name: "Phone")]))
        assertPOSIX(ESTALE) { _ = try adapter.node(file.fileID) }
    }

    func testRefreshInvalidatesCachedNodesEvenWhenSessionGenerationIsSame() throws {
        let (_, adapter) = fixture(root: [entry(10, "file")])
        let storage = try XCTUnwrap(adapter.children(of: adapter.root).first)
        let file = try XCTUnwrap(adapter.children(of: storage).first)
        _ = try adapter.refreshStorage()
        assertPOSIX(ESTALE) { _ = try adapter.node(file.fileID) }
    }

    func testDisconnectAndCancellationAreReported() throws {
        let (source, adapter) = fixture()
        source.replace(.init(generation: generation, namespace: UUID(), state: .disconnected,
                             storageState: .disconnected, storages: []))
        assertPOSIX(ENOTCONN) { _ = try adapter.children(of: adapter.root) }
        adapter.cancel()
        XCTAssertTrue(source.cancelled)
        XCTAssertEqual(adapter.snapshot.state, .cancelled)
    }

    func testPathTraversalAndControlNamesRejected() throws {
        for bad in ["../escape", "a/b", ".", "..", "line\nbreak", String(repeating: "n", count: 256)] {
            let (_, adapter) = fixture(root: [entry(10, bad)])
            let storage = try XCTUnwrap(adapter.children(of: adapter.root).first)
            assertPOSIX(EINVAL) { _ = try adapter.children(of: storage) }
        }
    }

    func testReadOnlyMutationsFailExplicitly() {
        let (_, adapter) = fixture()
        XCTAssertEqual((adapter.mutationError as NSError).code, Int(EROFS))
    }

    func testConcurrentOperationsAreRejected() throws {
        final class BlockingSource: MTPMetadataSource {
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            var value = MTPMetadataSnapshot(generation: UUID(), state: .available, storageState: .available,
                                            storages: [.init(generation: UUID(), id: 77, name: "Phone")])
            var wasCancelled = false
            var snapshot: MTPMetadataSnapshot { value }
            func enter(storage: UInt32, path: [MTPMetadataObjectIdentity]) throws -> MTPMetadataSnapshot {
                entered.signal(); release.wait()
                if wasCancelled { throw posix(ECANCELED) }
                return .init(generation: value.generation, state: .complete, storageState: .available,
                             storages: value.storages, directoryStorage: storage)
            }
            func continueListing() throws -> MTPMetadataSnapshot { value }
            func refresh() throws -> MTPMetadataSnapshot { value }
            func cancel() {
                wasCancelled = true
                value = .init(generation: value.generation, namespace: UUID(), state: .cancelled,
                              storageState: .cancelled, storages: [])
                release.signal()
            }
        }
        let source = BlockingSource(), adapter = MTPMetadataAdapter(source: source)
        let root = adapter.root
        let storage = try XCTUnwrap(try adapter.children(of: root).first)
        let done = expectation(description: "first operation")
        DispatchQueue.global().async { _ = try? adapter.children(of: storage); done.fulfill() }
        XCTAssertEqual(source.entered.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try adapter.children(of: storage))
        adapter.cancel()
        wait(for: [done], timeout: 2)
        XCTAssertEqual(adapter.snapshot.state, .cancelled)
    }

    func testFSKitMetadataVolumeExplicitlyRejectsReadsAndWrites() {
        let source = FixtureSource(generation: generation)
        let adapter = MTPMetadataAdapter(source: source)
        let volume = MTPMetadataVolume(adapter: adapter, volumeUUID: generation)
        XCTAssertEqual((volume.activationError as NSError).code, Int(EOPNOTSUPP))
        XCTAssertEqual((volume.contentReadError as NSError).code, Int(EOPNOTSUPP))
        volume.write(contents: Data([1]), to: volume.rootItem, at: 0) { count, error in
            XCTAssertEqual(count, 0); XCTAssertEqual((error as NSError?)?.code, Int(EROFS))
        }
        let name = FSFileName(string: "new")
        let attributes = FSItem.SetAttributesRequest()
        var rejected = 0
        func check(_ error: Error?) {
            XCTAssertEqual((error as NSError?)?.code, Int(EROFS)); rejected += 1
        }
        volume.setAttributes(attributes, on: volume.rootItem) { _, error in check(error) }
        volume.createItem(named: name, type: .file, inDirectory: volume.rootItem, attributes: attributes) { _, _, error in check(error) }
        volume.createSymbolicLink(named: name, inDirectory: volume.rootItem, attributes: attributes, linkContents: name) { _, _, error in check(error) }
        volume.createLink(to: volume.rootItem, named: name, inDirectory: volume.rootItem) { _, error in check(error) }
        volume.removeItem(volume.rootItem, named: name, fromDirectory: volume.rootItem) { check($0) }
        volume.renameItem(volume.rootItem, inDirectory: volume.rootItem, named: name, to: name, inDirectory: volume.rootItem, overItem: nil) { _, error in check(error) }
        XCTAssertEqual(rejected, 6)
    }

    func testBoundedSyntheticContentReaderValidationAndErrors() throws {
        final class Provider: MTPReadOnlyContentProvider {
            var result: MTPContentReadResult = .bytes(Data([1, 2, 3, 4]))
            var error: MTPContentReadError?
            var cancelDuringRead = false
            var calls = 0
            func read(_ request: MTPContentReadRequest, cancellation: MTPContentCancellation) throws -> MTPContentReadResult {
                calls += 1
                if cancelDuringRead { cancellation.cancel() }
                if let error { throw error }
                return result
            }
        }
        let generation = UUID(), namespace = UUID()
        let reference = MTPContentReference(identity: .init(generation: generation, storage: 0x10001, handle: 22),
                                            namespace: namespace, knownSize: 6)
        let request = try MTPContentReadRequest(reference: reference, offset: 2, length: 10)
        XCTAssertEqual(request.offset, 2); XCTAssertEqual(request.length, 4)
        let provider = Provider()
        var current = true
        let reader = MTPBoundedContentReader(provider: provider, isCurrent: { _ in current })
        XCTAssertEqual(try reader.read(request, cancellation: MTPContentCancellation()), .bytes(Data([1, 2, 3, 4])))
        XCTAssertEqual(provider.calls, 1)

        provider.result = .endOfFile
        XCTAssertThrowsError(try reader.read(request, cancellation: MTPContentCancellation())) {
            XCTAssertEqual($0 as? MTPContentReadError, .corrupted(expected: 4, actual: 0))
        }
        let eof = try MTPContentReadRequest(reference: reference, offset: 6, length: 1)
        XCTAssertEqual(try reader.read(eof, cancellation: MTPContentCancellation()), .endOfFile)

        provider.result = .bytes(Data([1]))
        XCTAssertThrowsError(try reader.read(request, cancellation: MTPContentCancellation())) {
            XCTAssertEqual($0 as? MTPContentReadError, .corrupted(expected: 4, actual: 1))
        }
        provider.error = .partialTransfer(expected: 4, actual: 2)
        XCTAssertThrowsError(try reader.read(request, cancellation: MTPContentCancellation())) {
            XCTAssertEqual($0 as? MTPContentReadError, .partialTransfer(expected: 4, actual: 2))
        }
        for failure: MTPContentReadError in [.timedOut, .disconnected] {
            provider.error = failure
            XCTAssertThrowsError(try reader.read(request, cancellation: MTPContentCancellation())) {
                XCTAssertEqual($0 as? MTPContentReadError, failure)
            }
        }

        provider.error = nil
        current = false
        let previousCalls = provider.calls
        XCTAssertThrowsError(try reader.read(request, cancellation: MTPContentCancellation())) {
            XCTAssertEqual($0 as? MTPContentReadError, .staleReference)
        }
        XCTAssertEqual(provider.calls, previousCalls)
        current = true
        let staleReferences = [
            MTPContentReference(identity: .init(generation: UUID(), storage: reference.identity.storage, handle: reference.identity.handle), namespace: namespace, knownSize: 6),
            MTPContentReference(identity: .init(generation: generation, storage: reference.identity.storage + 1, handle: reference.identity.handle), namespace: namespace, knownSize: 6),
            MTPContentReference(identity: .init(generation: generation, storage: reference.identity.storage, handle: reference.identity.handle + 1), namespace: namespace, knownSize: 6),
            MTPContentReference(identity: reference.identity, namespace: UUID(), knownSize: 6)
        ]
        let identityReader = MTPBoundedContentReader(provider: provider, isCurrent: { $0 == reference })
        for stale in staleReferences {
            let staleRequest = try MTPContentReadRequest(reference: stale, offset: 0, length: 1)
            XCTAssertThrowsError(try identityReader.read(staleRequest, cancellation: MTPContentCancellation())) {
                XCTAssertEqual($0 as? MTPContentReadError, .staleReference)
            }
        }
        let token = MTPContentCancellation(); token.cancel()
        XCTAssertThrowsError(try reader.read(request, cancellation: token)) {
            XCTAssertEqual($0 as? MTPContentReadError, .cancelled)
        }
        provider.cancelDuringRead = true
        XCTAssertThrowsError(try reader.read(request, cancellation: MTPContentCancellation())) {
            XCTAssertEqual($0 as? MTPContentReadError, .cancelled)
        }
    }

    func testContentRequestsRejectUnknownSizesAndInvalidRanges() throws {
        let ref = MTPContentReference(identity: .init(generation: UUID(), storage: 1, handle: 2),
                                     namespace: UUID(), knownSize: nil)
        XCTAssertThrowsError(try MTPContentReadRequest(reference: ref, offset: 0, length: 1))
        let known = MTPContentReference(identity: ref.identity, namespace: ref.namespace, knownSize: UInt64.max)
        for (offset, length) in [(-1, 1), (0, 0), (0, MTPContentReadRequest.maximumLength + 1), (Int64.max, 4)] {
            XCTAssertThrowsError(try MTPContentReadRequest(reference: known, offset: Int64(offset), length: length))
        }
    }
}
