import XCTest
import FSKit
@testable import HelloFS

final class HelloFSTests: XCTestCase {
    let tree = MemoryTree()
    func assertPOSIX(_ code: Int32, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain, file: file, line: line)
            XCTAssertEqual((error as NSError).code, Int(code), file: file, line: line)
        }
    }
    func testTreeAndExactContents() throws {
        XCTAssertEqual(tree.nodes.count, 4)
        XCTAssertEqual(try tree.lookup("Documents", in: 2).id, 3)
        XCTAssertEqual(try tree.lookup("hello.txt", in: 3).id, 5)
        XCTAssertEqual(try tree.read(5, offset: 0, length: 1000), Data("Hello from native FSKit!\n".utf8))
        XCTAssertEqual(try tree.read(4, offset: 0, length: 1000), Data("MacdroidBridge FSKit Hello World\nRead-only, in-memory filesystem. No USB or MTP connection.\n".utf8))
        XCTAssertEqual(try tree.lookup(".", in: 3).id, 3)
        XCTAssertEqual(try tree.lookup("..", in: 3).id, 2)
        XCTAssertEqual(try tree.lookup("..", in: 2).id, 2)
    }
    func testLookupErrorsAndCaseSensitivity() {
        assertPOSIX(ENOENT) { _ = try tree.lookup("documents", in: 2) }
        assertPOSIX(ENOENT) { _ = try tree.lookup("hello.txt", in: 2) }
        assertPOSIX(ENOTDIR) { _ = try tree.lookup("anything", in: 5) }
        assertPOSIX(ENOENT) { _ = try tree.node(100) }
    }
    func testReadBoundaries() throws {
        XCTAssertEqual(try tree.read(5, offset: 6, length: 4), Data("from".utf8))
        XCTAssertEqual(try tree.read(5, offset: 24, length: Int.max), Data("\n".utf8))
        XCTAssertTrue(try tree.read(5, offset: 25, length: 1).isEmpty)
        XCTAssertTrue(try tree.read(5, offset: Int64.max, length: Int.max).isEmpty)
        XCTAssertTrue(try tree.read(5, offset: 0, length: 0).isEmpty)
        assertPOSIX(EINVAL) { _ = try tree.read(5, offset: -1, length: 1) }
        assertPOSIX(EINVAL) { _ = try tree.read(5, offset: 0, length: -1) }
        assertPOSIX(EISDIR) { _ = try tree.read(3, offset: 0, length: 1) }
    }
    func testEnumerationAndResumption() throws {
        let all = try tree.entries(in: 2, cookie: 0, includeDots: true)
        XCTAssertEqual(all.map(\.name), [".", "..", "Documents", "README.txt"])
        XCTAssertEqual(all.map(\.nextCookie), [1, 2, 3, 4])
        // Simulate a packer accepting one entry per buffer, then resuming.
        var cookie: UInt64 = 0
        var names: [String] = []
        while let first = try tree.entries(in: 2, cookie: cookie, includeDots: true).first {
            names.append(first.name); cookie = first.nextCookie
        }
        XCTAssertEqual(names, all.map(\.name))
        XCTAssertEqual(try tree.entries(in: 2, cookie: 0, includeDots: false).map(\.name), ["Documents", "README.txt"])
        XCTAssertEqual(try tree.entries(in: 2, cookie: 3, includeDots: false).map(\.name), ["README.txt"])
        XCTAssertEqual(try tree.entries(in: 3, cookie: 0, includeDots: false).map(\.name), ["hello.txt"])
        XCTAssertTrue(try tree.entries(in: 2, cookie: 4, includeDots: true).isEmpty)
        assertPOSIX(Int32(FSError.Code.invalidDirectoryCookie.rawValue)) { _ = try tree.entries(in: 2, cookie: UInt64.max, includeDots: true) }
        assertPOSIX(ENOTDIR) { _ = try tree.entries(in: 5, cookie: 0, includeDots: true) }
    }
    func testResourceValidationAndProbe() {
        let fs = HelloFileSystem()
        for string in ["macdroidbridge://hello", "MACDROIDBRIDGE://hello/"] {
            let resource = FSGenericURLResource(url: URL(string: string)!)
            XCTAssertTrue(HelloFileSystem.accepts(resource))
            fs.probeResource(resource: resource) { result, error in
                XCTAssertNil(error); XCTAssertEqual(result?.result, .usable)
                XCTAssertEqual(result?.name, "MacdroidBridge")
            }
        }
        for string in ["file:///tmp/hello", "macdroidbridge://other", "macdroidbridge://hello/extra", "macdroidbridge://hello?x=1", "macdroidbridge://user@hello", "macdroidbridge://hello:123", "macdroidbridge://hello#fragment"] {
            let resource = FSGenericURLResource(url: URL(string: string)!)
            XCTAssertFalse(HelloFileSystem.accepts(resource))
            fs.probeResource(resource: resource) { result, error in
                XCTAssertNil(error); XCTAssertEqual(result?.result, .notRecognized)
            }
        }
    }
    func testAdapterLookupAttributesAndForeignItems() throws {
        let volume = HelloVolume()
        let rootItem = volume.rootItem
        volume.lookupItem(named: FSFileName(string: "README.txt"), inDirectory: rootItem) { item, name, error in
            XCTAssertNil(error); XCTAssertEqual(name?.string, "README.txt")
            guard let item else { XCTFail("Missing item"); return }
            volume.getAttributes(FSItem.GetAttributesRequest(), of: item) { attrs, error in
                XCTAssertNil(error); XCTAssertEqual(attrs?.mode, 0o444)
                XCTAssertEqual(attrs?.type, .file); XCTAssertEqual(attrs?.fileID.rawValue, 4)
                XCTAssertEqual(attrs?.size, UInt64(self.tree.nodes[4]!.contents!.count))
                XCTAssertEqual(attrs?.inhibitKernelOffloadedIO, true)
            }
        }
        volume.getAttributes(FSItem.GetAttributesRequest(), of: HelloItem(2)) { attrs, error in
            XCTAssertNil(attrs); XCTAssertEqual((error as NSError?)?.code, Int(ESTALE))
        }
        let directory = volume.attributes(for: try tree.node(3))
        XCTAssertEqual(directory.mode, 0o555); XCTAssertEqual(directory.type, .directory)
        XCTAssertEqual(directory.parentID.rawValue, 2)
    }
    func testEveryRequiredMutationIsReadOnly() {
        let volume = HelloVolume(), item = HelloItem(5), directory = HelloItem(2)
        let name = FSFileName(string: "new"), attrs = FSItem.SetAttributesRequest()
        if #available(macOS 26.4, *) { XCTAssertTrue(volume.requestedMountOptions.contains(.readOnly)) }
        var callbacks = 0
        func check(_ error: Error?) {
            callbacks += 1
            XCTAssertEqual((error as NSError?)?.domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError?)?.code, Int(EROFS))
        }
        volume.write(contents: Data([1]), to: item, at: 0) { count, error in XCTAssertEqual(count, 0); check(error) }
        volume.setAttributes(attrs, on: item) { result, error in XCTAssertNil(result); check(error) }
        volume.createItem(named: name, type: .file, inDirectory: directory, attributes: attrs) { item, name, error in XCTAssertNil(item); XCTAssertNil(name); check(error) }
        volume.createSymbolicLink(named: name, inDirectory: directory, attributes: attrs, linkContents: name) { item, name, error in XCTAssertNil(item); XCTAssertNil(name); check(error) }
        volume.createLink(to: item, named: name, inDirectory: directory) { name, error in XCTAssertNil(name); check(error) }
        volume.removeItem(item, named: name, fromDirectory: directory) { check($0) }
        volume.renameItem(item, inDirectory: directory, named: name, to: name, inDirectory: directory, overItem: nil) { name, error in XCTAssertNil(name); check(error) }
        XCTAssertEqual(callbacks, 7)
        XCTAssertEqual(try tree.read(5, offset: 0, length: 100), Data("Hello from native FSKit!\n".utf8))
    }
}
