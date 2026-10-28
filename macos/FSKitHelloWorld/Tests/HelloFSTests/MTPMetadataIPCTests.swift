import XCTest
import Foundation
import MTPMetadataContracts
@testable import HelloFS

private final class IPCFixture: MTPMetadataSource {
    let lock = NSLock()
    var value: MTPMetadataSnapshot
    var listingState: MTPMetadataSnapshot.State = .complete
    var entered = 0
    var cancellations = 0
    var gate: DispatchSemaphore?
    var started: (() -> Void)?
    init() {
        let generation = UUID()
        value = .init(generation: generation, state: .available, storageState: .available,
                      storages: [.init(generation: generation, id: 77, name: "Phone")])
    }
    var snapshot: MTPMetadataSnapshot { lock.lock(); defer { lock.unlock() }; return value }
    func enter(storage: UInt32, path: [MTPMetadataObjectIdentity]) throws -> MTPMetadataSnapshot {
        started?(); gate?.wait()
        lock.lock(); defer { lock.unlock() }
        entered += 1
        let parent = path.last?.handle ?? 0
        value = .init(generation: value.generation, namespace: value.namespace, state: listingState,
                      storageState: .available, storages: value.storages, directoryStorage: storage,
                      directoryHandle: parent, entries: parent == 0 ? [
                        .init(generation: value.generation, storage: storage, handle: 10, parent: 0,
                              name: "写真", isDirectory: true, size: nil, format: 0x3001),
                        .init(generation: value.generation, storage: storage, handle: 11, parent: 0,
                              name: "é.txt", isDirectory: false, size: nil, format: 0x3000),
                        .init(generation: value.generation, storage: storage, handle: 12, parent: 0,
                              name: "é.txt", isDirectory: false, size: 8, format: 0x3000)] : [])
        return value
    }
    func continueListing() throws -> MTPMetadataSnapshot { snapshot }
    func refresh() throws -> MTPMetadataSnapshot {
        lock.lock(); defer { lock.unlock() }
        value = .init(generation: value.generation, namespace: UUID(), state: .available,
                      storageState: .available, storages: value.storages)
        return value
    }
    func cancel() { lock.lock(); cancellations += 1; lock.unlock(); gate?.signal() }
    func changeSession() {
        lock.lock(); defer { lock.unlock() }
        value = .init(generation: UUID(), state: .disconnected, storageState: .disconnected, storages: [])
    }
}
private final class AlteredTransport: MTPMetadataTransport {
    let base: MTPMetadataTransport
    var alter: ((Data) throws -> Data)?
    init(_ base: MTPMetadataTransport) { self.base = base }
    func exchange(_ data: Data) throws -> Data {
        let reply = try base.exchange(data)
        return try alter?(reply) ?? reply
    }
    func invalidate(session: UUID, cancelled: Bool) { base.invalidate(session: session, cancelled: cancelled) }
}

final class MTPMetadataIPCTests: XCTestCase {
    private func fixture() throws -> (IPCFixture, MTPMetadataService, MTPMetadataClient) {
        let source = IPCFixture()
        let service = MTPMetadataService(source: source)
        return (source, service, try MTPMetadataClient(transport: MTPInProcessMetadataTransport(service: service)))
    }
    private func exchange(_ service: MTPMetadataService, _ request: MTPIPCRequest) throws -> MTPIPCResponse {
        try JSONDecoder().decode(MTPIPCResponse.self, from: service.receive(JSONEncoder().encode(request)))
    }
    func testMessageRoundTripAndUnknownOperationsRejected() throws {
        var request = MTPIPCRequest(operation: .directory)
        request.path = [.init(generation: UUID(), storage: 77, handle: 10)]
        let decoded = try JSONDecoder().decode(MTPIPCRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.id, request.id); XCTAssertEqual(decoded.path, request.path)
        let service = MTPMetadataService(source: IPCFixture())
        for operation in ["read", "write", "create", "delete", "rename"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            object["operation"] = operation
            XCTAssertThrowsError(try service.receive(JSONSerialization.data(withJSONObject: object)))
        }
        request.version = 42
        XCTAssertEqual(try exchange(service, request).error, .unsupportedVersion)
    }
    func testInitializationAttachmentAndStorageEnumeration() throws {
        let service = MTPMetadataService()
        XCTAssertThrowsError(try MTPMetadataClient(transport: MTPInProcessMetadataTransport(service: service)))
        let source = IPCFixture(); service.attach(source)
        let client = try MTPMetadataClient(transport: MTPInProcessMetadataTransport(service: service))
        XCTAssertEqual(try client.enumerateStorages().storages.map(\.id), [77])
        XCTAssertEqual(source.entered, 0)
    }
    func testAdapterUnicodeDuplicateNamesUnknownSizeAndReadOnly() throws {
        let (_, _, client) = try fixture()
        let adapter = MTPMetadataAdapter(source: client)
        let storage = try XCTUnwrap(adapter.children(of: adapter.root).first)
        let children = try adapter.children(of: storage)
        XCTAssertEqual(children.first?.name, "写真")
        XCTAssertEqual(Set(children.map(\.name)).count, 3)
        XCTAssertThrowsError(try adapter.attributesSize(of: children[1]))
        XCTAssertEqual(try adapter.attributesSize(of: children[2]), 8)
        XCTAssertThrowsError(try adapter.readContents(of: children[2], offset: 0, length: 1))
        XCTAssertEqual((adapter.mutationError as NSError).code, Int(EROFS))
        XCTAssertFalse(adapter.supportsFileContentReads)
        XCTAssertEqual(try adapter.children(of: children[0]).count, 0)
    }
    func testConcurrentRequestsAreCorrelatedAndSerialized() throws {
        let (source, _, client) = try fixture()
        let completed = expectation(description: "concurrent"); completed.expectedFulfillmentCount = 20
        for _ in 0..<20 {
            DispatchQueue.global().async {
                do { let result = try client.enter(storage: 77, path: []); XCTAssertEqual(result.entries.count, 3) }
                catch { XCTFail("\(error)") }
                completed.fulfill()
            }
        }
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(source.entered, 20)
    }
    func testCancellationInterruptsInFlightOperation() throws {
        let (source, _, client) = try fixture()
        let started = expectation(description: "started"), finished = expectation(description: "finished")
        source.gate = DispatchSemaphore(value: 0); source.started = { started.fulfill() }
        DispatchQueue.global().async {
            do { _ = try client.enter(storage: 77, path: []); XCTFail("Expected cancellation") }
            catch { XCTAssertEqual(error as? MTPIPCError, .cancelled) }
            finished.fulfill()
        }
        wait(for: [started], timeout: 2); client.cancel()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(client.snapshot.storageState, .cancelled)
        XCTAssertEqual(source.cancellations, 1)
        XCTAssertThrowsError(try client.refresh())
    }
    func testDisconnectInterruptsInFlightOperation() throws {
        let (source, _, client) = try fixture()
        let started = expectation(description: "started"), finished = expectation(description: "finished")
        source.gate = DispatchSemaphore(value: 0); source.started = { started.fulfill() }
        DispatchQueue.global().async {
            do { _ = try client.enter(storage: 77, path: []); XCTFail("Expected disconnect") }
            catch { XCTAssertEqual(error as? MTPIPCError, .disconnected) }
            finished.fulfill()
        }
        wait(for: [started], timeout: 2); client.disconnect()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(client.snapshot.storageState, .disconnected)
    }
    func testExternalStorageNamespaceInvalidation() throws {
        let (source, _, client) = try fixture()
        _ = try source.refresh()
        XCTAssertThrowsError(try client.enter(storage: 77, path: [])) { XCTAssertEqual($0 as? MTPIPCError, .staleNamespace) }
        XCTAssertEqual(source.entered, 0)
    }
    func testMalformedResponseFailsClosed() throws {
        let service = MTPMetadataService(source: IPCFixture())
        let transport = AlteredTransport(MTPInProcessMetadataTransport(service: service))
        let client = try MTPMetadataClient(transport: transport)
        transport.alter = { _ in Data("invalid".utf8) }
        XCTAssertThrowsError(try client.enumerateStorages())
        XCTAssertEqual(client.snapshot.storageState, .disconnected)
    }
    func testDisconnectInvalidatesAdapterNamespace() throws {
        let (_, _, client) = try fixture()
        let adapter = MTPMetadataAdapter(source: client), old = client.snapshot.namespace
        client.disconnect()
        XCTAssertNotEqual(old, client.snapshot.namespace)
        XCTAssertThrowsError(try adapter.children(of: adapter.root))
        XCTAssertThrowsError(try client.enumerateStorages()) { XCTAssertEqual($0 as? MTPIPCError, .disconnected) }
    }
    func testRestartRejectsOldClientWithoutDisconnectingReplacement() throws {
        let (_, service, oldClient) = try fixture()
        let replacement = IPCFixture(); service.attach(replacement)
        let newClient = try MTPMetadataClient(transport: MTPInProcessMetadataTransport(service: service))
        XCTAssertThrowsError(try oldClient.enumerateStorages())
        XCTAssertEqual(try newClient.enter(storage: 77, path: []).entries.count, 3)
        XCTAssertEqual(replacement.cancellations, 0)
    }
    func testRestartDuringRequestRejectsOldResponse() throws {
        let (source, service, client) = try fixture()
        let started = expectation(description: "started"), finished = expectation(description: "finished")
        source.gate = DispatchSemaphore(value: 0); source.started = { started.fulfill() }
        DispatchQueue.global().async {
            do { _ = try client.enter(storage: 77, path: []); XCTFail("Expected stale response") }
            catch { XCTAssertTrue(error is MTPIPCError) }
            finished.fulfill()
        }
        wait(for: [started], timeout: 2)
        service.attach(IPCFixture())
        wait(for: [finished], timeout: 2)
        let fresh = try MTPMetadataClient(transport: MTPInProcessMetadataTransport(service: service))
        XCTAssertEqual(try fresh.enumerateStorages().storages.count, 1)
    }
    func testTamperedCorrelationSessionAndNamespaceFailClosed() throws {
        for field in ["id", "session", "namespace", "sequence"] {
            let service = MTPMetadataService(source: IPCFixture())
            let transport = AlteredTransport(MTPInProcessMetadataTransport(service: service))
            let client = try MTPMetadataClient(transport: transport)
            transport.alter = { data in
                var response = try JSONDecoder().decode(MTPIPCResponse.self, from: data)
                switch field {
                case "id": response.id = UUID()
                case "session": response.session = UUID()
                case "sequence": response.sequence += 1
                default:
                    let snapshot = try XCTUnwrap(response.snapshot)
                    response.snapshot = .init(generation: snapshot.generation, namespace: UUID(), state: .available,
                                              storageState: .available, storages: snapshot.storages)
                }
                return try JSONEncoder().encode(response)
            }
            XCTAssertThrowsError(try client.enumerateStorages()) { XCTAssertEqual($0 as? MTPIPCError, .staleResponse) }
            XCTAssertEqual(client.snapshot.storageState, .disconnected)
        }
    }
    func testPartialAvailableAndEmptyAreNotCompleteDirectories() throws {
        for state: MTPMetadataSnapshot.State in [.partial, .available, .empty] {
            let (source, _, client) = try fixture(); source.listingState = state
            let adapter = MTPMetadataAdapter(source: client)
            let storage = try XCTUnwrap(adapter.children(of: adapter.root).first)
            XCTAssertThrowsError(try adapter.children(of: storage))
            XCTAssertEqual(client.snapshot.state, state)
        }
    }
    func testUnavailableDirectoryRemainsFailure() throws {
        let (source, _, client) = try fixture(); source.listingState = .failed("unavailable")
        let adapter = MTPMetadataAdapter(source: client)
        let storage = try XCTUnwrap(adapter.children(of: adapter.root).first)
        XCTAssertThrowsError(try adapter.children(of: storage))
    }
    func testRefreshInvalidatesOldStorageAndHandles() throws {
        let (_, _, client) = try fixture()
        let adapter = MTPMetadataAdapter(source: client)
        let storage = try XCTUnwrap(adapter.children(of: adapter.root).first)
        let directory = try XCTUnwrap(adapter.children(of: storage).first)
        _ = try adapter.refreshStorage()
        XCTAssertThrowsError(try adapter.children(of: storage))
        XCTAssertThrowsError(try adapter.children(of: directory))
        XCTAssertThrowsError(try client.enter(storage: 77, path: [.init(generation: directory.generation, storage: 77, handle: 10)]))
    }
    func testStaleSessionStorageAndUnknownHandleNeverReachSource() throws {
        for kind in 0..<3 {
            let (source, _, client) = try fixture()
            if kind == 0 { source.changeSession() }
            let path: [MTPMetadataObjectIdentity] = kind == 2 ? [.init(generation: client.snapshot.generation, storage: 77, handle: 999)] : []
            XCTAssertThrowsError(try client.enter(storage: kind == 1 ? 88 : 77, path: path))
            XCTAssertEqual(source.entered, 0)
        }
    }
    func testReplayedRequestIsRejected() throws {
        let service = MTPMetadataService(source: IPCFixture())
        let hello = try exchange(service, MTPIPCRequest(operation: .initialize))
        var request = MTPIPCRequest(operation: .storages)
        request.session = hello.session; request.sequence = 1
        request.namespace = hello.snapshot?.namespace; request.generation = hello.snapshot?.generation
        XCTAssertNil(try exchange(service, request).error)
        XCTAssertEqual(try exchange(service, request).error, .invalidSequence)
    }
}
