import Foundation
import XCTest
@testable import MTPProbeLib
import MTPMetadataContracts

final class MTPFolderBrowserTests: XCTestCase {
    enum TestError: Error { case metadata, close }
    final class Synthetic: MTPBrowserSession {
        var openCount=0, closeCount=0, shutdownCount=0, infos=0, handleQueries=0
        var root: [UInt32] = Array(1...45)
        var children: [UInt32] = [100,101]
        var parent: UInt32? = nil
        var names: [UInt32:String] = [:]
        var size: UInt32 = 10
        var failAt: Int?; var onInfo: (() -> Void)?; var closeFails=false
        var wrongParent=false, wrongStorage=false
        func open() throws {openCount += 1}
        func close() throws {closeCount += 1; if closeFails {throw TestError.close}}
        func shutdown() {shutdownCount += 1}
        func storageIDs() throws -> [UInt32] {[0x20002]}
        func storageInfo(_ id: UInt32) throws -> MTPStorageInfo {
            MTPStorageInfo(storageID:id, storageType:3, filesystemType:2, accessCapability:0, maxCapacity:1000, freeSpaceInBytes:500, freeSpaceInObjects:100, storageDescription:"Internal", volumeIdentifier:"")
        }
        func handles(storage: UInt32, parent: UInt32?) throws -> [UInt32] {
            handleQueries += 1; self.parent=parent; return parent == nil ? root : children
        }
        func info(_ handle: UInt32) throws -> MTPObjectInfo {
            infos += 1; onInfo?(); if infos == failAt {throw TestError.metadata}
            return MTPObjectInfo(objectHandle:handle, storageID:wrongStorage ? 99 : 0x20002, objectFormat: handle==1 ? 0x3001 : 0x3000,
                protectionStatus:0, objectCompressedSize:size, thumbFormat:0, thumbCompressedSize:0,
                thumbPixWidth:0, thumbPixHeight:0, imagePixWidth:0, imagePixHeight:0, imageBitDepth:0,
                parentObject:wrongParent ? 999 : (parent ?? 0), associationType:handle==1 ? 1 : 0,
                associationDesc:0, sequenceNumber:0, filename:names[handle] ?? "entry-\(handle)", dateCreated:"", dateModified:"", keywords:"")
        }
    }
    func setup(_ s: Synthetic = Synthetic()) throws -> (MTPFolderBrowser,Synthetic,MTPFolderBrowser.Storage) {
        let b=MTPFolderBrowser(); let v=try b.start(s); return (b,s,try XCTUnwrap(v.storages.first))
    }
    func test45Handles32Then13WithNoRepeatedHandleQuery() throws {
        let (b,s,store)=try setup(); let first=try b.root(store)
        XCTAssertEqual(first.entries.count,32); XCTAssertEqual(first.total,45); XCTAssertEqual(first.phase,.partial); XCTAssertTrue(first.more)
        let last=try b.loadMore(); XCTAssertEqual(last.entries.count,45); XCTAssertEqual(last.phase,.completed); XCTAssertFalse(last.more)
        XCTAssertEqual(s.infos,45); XCTAssertEqual(s.handleQueries,1)
        XCTAssertThrowsError(try b.loadMore())
        try b.close(); XCTAssertEqual(s.closeCount,1)
    }
    func testNavigationAndBackAreImmediateChildrenOnly() throws {
        let (b,s,store)=try setup(); let root=try b.root(store); let folder=try XCTUnwrap(root.entries.first)
        let child=try b.open(folder.id); XCTAssertEqual(child.entries.count,2); XCTAssertEqual(child.directory?.handle,1)
        XCTAssertEqual(child.entries.map(\.parent),[1,1]); XCTAssertEqual(s.handleQueries,2)
        let back=try b.back(); XCTAssertNil(back.directory?.handle); XCTAssertEqual(back.phase,.partial); XCTAssertEqual(s.handleQueries,3)
        try b.close()
    }
    func testEmptyDirectory() throws {
        let s=Synthetic(); s.root=[]; let(b,_,store)=try setup(s); let v=try b.root(store)
        XCTAssertTrue(v.entries.isEmpty); XCTAssertEqual(v.phase,.completed); XCTAssertFalse(v.more); XCTAssertEqual(s.infos,0)
    }
    func testDuplicateAndUnicodeNamesPreserveHandleIdentityAndUnknownSize() throws {
        let s=Synthetic(); s.root=[2,3,4,5]; s.names=[2:"same",3:"same",4:"é",5:"e\u{301}"]; s.size=0xFFFFFFFF
        let(b,_,store)=try setup(s); let v=try b.root(store)
        XCTAssertEqual(Set(v.entries.map(\.id)).count,4); XCTAssertTrue(v.entries.allSatisfy {$0.size == nil})
        XCTAssertEqual(Array(v.entries[2].name.utf8),[195,169]); XCTAssertEqual(Array(v.entries[3].name.utf8),[101,204,129])
        XCTAssertTrue(try v.presentation().contains("unknown")); XCTAssertTrue(try v.presentation().contains("completed"))
    }
    func testInvalidNamesParentsAndStorageFailClosed() throws {
        for name in ["",".","..","a/b","bad\nname","\0"] {
            let s=Synthetic(); s.names[1]=name; let(b,_,store)=try setup(s)
            XCTAssertThrowsError(try b.root(store)); XCTAssertEqual(b.snapshot.phase,.failed); XCTAssertFalse(b.snapshot.more)
        }
        for wrongParent in [true,false] {
            let s=Synthetic(); s.wrongParent=wrongParent; s.wrongStorage = !wrongParent
            let(b,_,store)=try setup(s); XCTAssertThrowsError(try b.root(store))
        }
    }
    func testDuplicateInvalidAndOverLimitHandles() throws {
        for handles: [UInt32] in [[0],[0xFFFFFFFF],[1,1],Array(1...4097)] {
            let s=Synthetic(); s.root=handles; let(b,_,store)=try setup(s)
            XCTAssertThrowsError(try b.root(store)); XCTAssertEqual(s.infos,0)
        }
    }
    func testReplacementRejectsOldIdentityAndOldStorage() throws {
        let(b,s,store)=try setup(); let old=try b.root(store).entries[0].id
        let replacement=Synthetic(); _=try b.start(replacement); XCTAssertEqual(s.closeCount,1)
        XCTAssertThrowsError(try b.open(old)); XCTAssertThrowsError(try b.root(store))
        XCTAssertEqual(replacement.infos,0)
    }
    func testStorageRemovalAndChangeInvalidateEntries() throws {
        for code: UInt16 in [0x4005,0x400C] {
            let(b,_,store)=try setup(); let id=try b.root(store).entries[0].id
            b.receiveStorageEvent(code:code,storage:store.id)
            XCTAssertTrue(b.snapshot.storages.isEmpty); XCTAssertTrue(b.snapshot.entries.isEmpty)
            XCTAssertThrowsError(try b.open(id)); XCTAssertThrowsError(try b.root(store))
        }
    }
    func testPartialFailureRetainsInspectedEntriesAndOriginalError() throws {
        let s=Synthetic(); s.failAt=5; let(b,_,store)=try setup(s)
        XCTAssertThrowsError(try b.root(store)) {XCTAssertTrue($0 is TestError)}
        XCTAssertEqual(b.snapshot.entries.count,4); XCTAssertEqual(b.snapshot.total,45); XCTAssertEqual(b.snapshot.phase,.failed)
        XCTAssertFalse(b.snapshot.more); XCTAssertTrue(b.lastError is TestError); XCTAssertThrowsError(try b.loadMore())
        try b.close(); XCTAssertEqual(s.closeCount,1)
    }
    func testCancellationDuringBatchInvalidatesAndDoesNotPublishLaterResult() throws {
        let(b,s,store)=try setup(); s.onInfo={b.cancel()}
        XCTAssertThrowsError(try b.root(store)); XCTAssertEqual(s.infos,1); XCTAssertEqual(b.snapshot.phase,.cancelled)
        XCTAssertTrue(b.snapshot.entries.isEmpty); XCTAssertThrowsError(try b.root(store)); XCTAssertGreaterThan(s.shutdownCount,0)
    }
    func testDisconnectedHandlesNeverReused() throws {
        let(b,s,store)=try setup(); let id=try b.root(store).entries[0].id; b.disconnected()
        XCTAssertEqual(b.snapshot.phase,.disconnected); XCTAssertThrowsError(try b.open(id)); XCTAssertGreaterThan(s.shutdownCount,0)
    }
    func testConcurrentNavigationRejectedAndLoadingVisible() throws {
        let(b,s,store)=try setup(); let entered=DispatchSemaphore(value:0), release=DispatchSemaphore(value:0)
        s.onInfo={if s.infos==1 {entered.signal(); _=release.wait(timeout:.now()+3)}}
        let done=expectation(description:"worker finishes")
        DispatchQueue.global().async {defer {done.fulfill()}; do {_=try b.root(store)} catch {XCTFail("\(error)")} }
        XCTAssertEqual(entered.wait(timeout:.now()+3),.success); XCTAssertEqual(b.snapshot.phase,.loading)
        XCTAssertThrowsError(try b.root(store)) {XCTAssertTrue($0 is MTPFolderBrowser.Failure)}
        release.signal(); wait(for:[done],timeout:5); XCTAssertEqual(s.handleQueries,1)
    }
    func testCloseErrorPreservedWithTransportRelease() throws {
        let(b,s,_)=try setup(); s.closeFails=true; XCTAssertThrowsError(try b.close())
        XCTAssertEqual(b.snapshot.phase,.failed); XCTAssertTrue(b.lastError is TestError); XCTAssertGreaterThan(s.shutdownCount,0)
    }
    func testProductionAdapterOnlyMetadataOpcodes() throws {
        let wire=MTPRootListingTests.Wire(); let device=MTPDevice(transport:wire)
        let browser=MTPFolderBrowser(); let v=try browser.start(MTPDeviceBrowserSession(device:device))
        let result=try browser.root(XCTUnwrap(v.storages.first)); XCTAssertEqual(result.entries.count,2)
        try browser.close()
        XCTAssertEqual(wire.commands.map {$0.0},[0x1002,0x1004,0x1005,0x1007,0x1008,0x1008,0x1003])
        XCTAssertEqual(wire.commands[3].1,[0x20002,0,0xFFFFFFFF])
    }
    func testStrictUTF16RejectsInvalidAndUnterminatedStrings() throws {
        for bytes: [UInt8] in [[2,0,0xD8,0,0],[1,65,0],[2,0,0,0,0]] {
            var reader=MTPDataReader(data:Data(bytes)); XCTAssertThrowsError(try reader.readMTPString(strict:true))
        }
    }
    func testFolderBrowserMetadataSourceMapsCompletePartialAndChildStates() throws {
        let (browser, _, storage) = try setup()
        let source = MTPFolderBrowserMetadataSource(browser: browser)
        XCTAssertEqual(source.snapshot.storageState, .available)
        let partial = try source.enter(storage: storage.id, path: [])
        XCTAssertEqual(partial.state, .partial)
        XCTAssertEqual(partial.entries.count, 32)
        let complete = try source.continueListing()
        XCTAssertEqual(complete.state, .complete)
        XCTAssertEqual(complete.entries.count, 45)
        let folder = try XCTUnwrap(complete.entries.first(where: { $0.isDirectory }))
        let child = try source.enter(storage: storage.id, path: [folder.identity])
        XCTAssertEqual(child.state, .complete)
        XCTAssertEqual(child.entries.count, 2)
        XCTAssertEqual(child.entries.map(\.parent), [folder.handle, folder.handle])
        try browser.close()
    }
    func testMetadataSourceRefreshRotatesNamespaceAndPreservesSessionGeneration() throws {
        let (browser, _, storage) = try setup()
        let source = MTPFolderBrowserMetadataSource(browser: browser)
        let before = source.snapshot
        let after = try source.refresh()
        XCTAssertEqual(after.generation, before.generation)
        XCTAssertNotEqual(after.namespace, before.namespace)
        XCTAssertEqual(after.storageState, .available)
        try browser.close()
    }
    func testChildWireSelectorAndHandleLimit() throws {
        let wire=MTPRootListingTests.Wire(); let d=MTPDevice(transport:wire)
        try d.openSession(); _=try d.getBrowserHandles(storage:0x20002,parent:7)
        XCTAssertEqual(wire.commands.last?.1,[0x20002,0,7])
        wire.handles=Array(1...4097)
        XCTAssertThrowsError(try d.getBrowserHandles(storage:0x20002,parent:nil))
        try d.closeSession(); d.shutdown()
    }
    func testSyntheticPresentationCoversProgressAndDisconnected() throws {
        let(b,_,store)=try setup(); let partial=try b.root(store)
        XCTAssertTrue(try partial.presentation().contains("partial"))
        XCTAssertTrue(try partial.presentation().contains("\"more\":true"))
        XCTAssertTrue(try partial.presentation().contains("\"inspected\":32"))
        _=try b.loadMore(); print("SYNTHETIC_BROWSER " + (try b.snapshot.presentation()))
        b.disconnected(); XCTAssertTrue(try b.snapshot.presentation().contains("disconnected"))
    }

    func testContinuationCannotCrossDirectoryOrRepeatBatch() throws {
        let(b,_,store)=try setup(); let first=try b.root(store); let token=try XCTUnwrap(first.continuation)
        let complete=try b.loadMore(token); XCTAssertEqual(complete.entries.count,45); XCTAssertNil(complete.continuation)
        XCTAssertThrowsError(try b.loadMore(token))
        let newListing=try b.root(store); XCTAssertNotEqual(newListing.continuation,token)
        XCTAssertThrowsError(try b.loadMore(token))
    }

}
