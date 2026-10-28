import Foundation
import XCTest
@testable import MTPProbeLib

final class MTPStorageRefreshTests: XCTestCase {
    enum Fault: Error { case wire }
    final class Session: MTPBrowserSession {
        var calls=0, opens=0, closes=0, shutdowns=0
        var ids: [UInt32] = []
        var failure=false
        var disconnected=false
        var hook: (() -> Void)?
        var infoHook: (() -> Void)?
        func open() throws {opens += 1}
        func close() throws {closes += 1}
        func shutdown() {shutdowns += 1}
        func storageIDs() throws -> [UInt32] {calls += 1; hook?(); if failure {throw Fault.wire}; return ids}
        func storageInfo(_ id: UInt32) throws -> MTPStorageInfo { try MTPFolderBrowserTests.Synthetic().storageInfo(id) }
        func handles(storage: UInt32, parent: UInt32?) throws -> [UInt32] {[1,2]}
        func info(_ handle: UInt32) throws -> MTPObjectInfo {infoHook?(); return try MTPFolderBrowserTests.Synthetic().info(handle)}
    }
    func testEmptyThenManualRefreshUsesSameWireSession() throws {
        let s=Session(), b=MTPFolderBrowser(); let first=try b.start(s)
        XCTAssertEqual(first.storageState,.emptySuccess); XCTAssertEqual(s.calls,1)
        XCTAssertTrue(try first.presentation().contains("The phone reported no available storage."))
        s.ids=[0x20002]; let next=try b.refreshStorage(annotation:"awake, File Transfer selected")
        XCTAssertEqual(next.storageState,.available); XCTAssertEqual(s.calls,2); XCTAssertEqual(s.opens,1); XCTAssertEqual(s.closes,0)
        XCTAssertEqual(b.refreshObservations.first?.mechanism,"same-session"); XCTAssertEqual(b.refreshObservations.first?.returnedStorageCount,1)
        try b.close(); XCTAssertEqual(s.closes,1)
    }
    func testRepeatedEmptyIsSuccessWithoutAutomaticRetry() throws {
        var now: TimeInterval=1; let s=Session(), b=MTPFolderBrowser(monotonicNow:{now})
        _=try b.start(s); XCTAssertEqual(try b.refreshStorage().storageState,.emptySuccess)
        now += 1; XCTAssertEqual(try b.refreshStorage().storageState,.emptySuccess)
        XCTAssertEqual(s.calls,3); XCTAssertEqual(b.refreshObservations.count,2); XCTAssertNil(b.lastError)
        now += 1; _=try b.refreshStorage(annotation:"a" + String(repeating:"\u{301}",count:10000))
        XCTAssertLessThanOrEqual(b.refreshObservations.last?.annotation?.utf8.count ?? 0,514)
    }
    func testNoTargetIsDeviceUnavailableWithOriginalErrorAndNoSession() {
        let b=MTPFolderBrowser(); let error=USBDiscoveryFailure(.interfaceValidation,"target policy/pre-open identity",detail:"noTarget")
        b.discoveryFailed(error); XCTAssertEqual(b.snapshot.storageState,.deviceUnavailable)
        XCTAssertTrue(b.lastError is USBDiscoveryFailure); XCTAssertNotEqual(b.snapshot.storageState,.emptySuccess)
        XCTAssertThrowsError(try b.refreshStorage()); XCTAssertTrue(b.refreshObservations.isEmpty)
    }
    func testTransportFailureIsNotEmptyAndIsNotRetried() throws {
        let s=Session(), b=MTPFolderBrowser(); _=try b.start(s); s.failure=true
        XCTAssertThrowsError(try b.refreshStorage()) {XCTAssertTrue($0 is Fault)}
        XCTAssertEqual(s.calls,2); XCTAssertEqual(b.snapshot.storageState,.transportFailure); XCTAssertTrue(b.lastError is Fault)
        XCTAssertEqual(b.refreshObservations.last?.result,.transportFailure); XCTAssertEqual(s.closes,1); XCTAssertEqual(s.shutdowns,1)
        XCTAssertThrowsError(try b.refreshStorage()); XCTAssertEqual(s.calls,2)
    }
    func testRapidDoubleRefreshSendsOnlyOneTransaction() throws {
        var now: TimeInterval=10; let s=Session(), b=MTPFolderBrowser(monotonicNow:{now}); _=try b.start(s)
        _=try b.refreshStorage(); now += 0.1
        XCTAssertThrowsError(try b.refreshStorage()); XCTAssertEqual(s.calls,2); XCTAssertEqual(b.refreshObservations.count,1)
        now += 1; _=try b.refreshStorage(); XCTAssertEqual(s.calls,3)
    }
    func testConcurrentRefreshDoesNotDuplicateRequest() throws {
        let s=Session(), b=MTPFolderBrowser(); _=try b.start(s)
        let entered=DispatchSemaphore(value:0), release=DispatchSemaphore(value:0)
        s.hook={entered.signal(); _=release.wait(timeout:.now()+3)}
        let done=expectation(description:"refresh")
        DispatchQueue.global().async {defer {done.fulfill()}; do {_=try b.refreshStorage()} catch {XCTFail("\(error)")} }
        XCTAssertEqual(entered.wait(timeout:.now()+3),.success)
        XCTAssertThrowsError(try b.refreshStorage()); release.signal(); wait(for:[done],timeout:5)
        XCTAssertEqual(s.calls,2); XCTAssertEqual(b.refreshObservations.count,1)
    }
    func testRefreshDuringMetadataIsRejectedThenInvalidatesOldListing() throws {
        let s=Session(), b=MTPFolderBrowser(); s.ids=[0x20002]; let start=try b.start(s)
        s.infoHook={do {_=try b.refreshStorage(); XCTFail("Refresh must reject concurrent metadata work")} catch {}}
        let listing=try b.root(XCTUnwrap(start.storages.first)); XCTAssertEqual(s.calls,1)
        let old=try XCTUnwrap(listing.entries.first?.id); s.infoHook=nil
        let refreshed=try b.refreshStorage(); XCTAssertEqual(s.calls,2); XCTAssertEqual(refreshed.generation,start.generation)
        XCTAssertTrue(refreshed.entries.isEmpty); XCTAssertNil(refreshed.continuation); XCTAssertThrowsError(try b.open(old))
    }
    func testChangedStorageAndReplacementInvalidateGeneration() throws {
        let s=Session(), b=MTPFolderBrowser(); s.ids=[0x20002]; let start=try b.start(s)
        let old=try b.root(XCTUnwrap(start.storages.first)).entries[0].id
        s.ids=[0x30003]; let refreshed=try b.refreshStorage(); XCTAssertNotEqual(refreshed.generation,start.generation)
        XCTAssertThrowsError(try b.open(old)); XCTAssertEqual(s.opens,1)
        let next=Session(); next.ids=[0x20002]; _=try b.start(next); XCTAssertThrowsError(try b.open(old)); XCTAssertEqual(s.closes,1)
    }
    func testCancellationDuringRefreshNeverPublishesAvailable() throws {
        let s=Session(), b=MTPFolderBrowser(); _=try b.start(s); s.ids=[0x20002]; s.hook={b.cancel()}
        XCTAssertThrowsError(try b.refreshStorage()); XCTAssertEqual(s.calls,2)
        XCTAssertEqual(b.snapshot.storageState,.cancelled); XCTAssertTrue(b.snapshot.storages.isEmpty)
        XCTAssertEqual(b.refreshObservations.last?.result,.cancelled); XCTAssertGreaterThan(s.shutdowns,0)
    }
    func testDisconnectDuringRefreshNeverPublishesAvailable() throws {
        let s=Session(), b=MTPFolderBrowser(); _=try b.start(s); s.ids=[0x20002]; s.hook={b.disconnected()}
        XCTAssertThrowsError(try b.refreshStorage()); XCTAssertEqual(s.calls,2)
        XCTAssertEqual(b.snapshot.storageState,.disconnected); XCTAssertTrue(b.snapshot.storages.isEmpty)
        XCTAssertEqual(b.refreshObservations.last?.result,.disconnected)
    }
    func testEventsNeverTriggerRefresh() throws {
        let s=Session(), b=MTPFolderBrowser(); _=try b.start(s)
        for code: UInt16 in [0x4004,0x4005,0x400C] {b.receiveStorageEvent(code:code,storage:0x20002)}
        XCTAssertEqual(s.calls,1); XCTAssertTrue(b.refreshObservations.isEmpty)
    }
    func testObservationsAreBoundedAndHaveNoNames() throws {
        var now: TimeInterval=0; let s=Session(), b=MTPFolderBrowser(monotonicNow:{now},wallNow:{Date(timeIntervalSince1970:123)})
        _=try b.start(s)
        for _ in 0..<65 {now += 1; _=try b.refreshStorage(annotation:String(repeating:"a",count:200))}
        XCTAssertEqual(b.refreshObservations.count,64); XCTAssertEqual(s.calls,66)
        XCTAssertEqual(b.refreshObservations.last?.annotation?.count,128)
        XCTAssertEqual(b.refreshObservations.last?.timestamp,Date(timeIntervalSince1970:123))
        let json=String(decoding:try JSONEncoder().encode(b.refreshObservations),as:UTF8.self)
        XCTAssertFalse(json.contains("filename")); XCTAssertFalse(json.contains("entries"))
    }
    func testActualAdapterRequeriesStorageOnceAndHasNoContentCommands() throws {
        let wire=MTPRootListingTests.Wire(); wire.storageIDs=[]
        let b=MTPFolderBrowser(); _=try b.start(MTPDeviceBrowserSession(device:MTPDevice(transport:wire)))
        wire.storageIDs=[0x20002]; XCTAssertEqual(try b.refreshStorage().storageState,.available); try b.close()
        XCTAssertEqual(wire.commands.map {$0.0},[0x1002,0x1004,0x1004,0x1005,0x1003])
        XCTAssertEqual(wire.closes,1)
    }
}
