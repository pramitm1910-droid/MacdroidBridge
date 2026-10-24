import XCTest
import FSKit
import Darwin
@testable import HelloFS

final class PathResourceTests: XCTestCase {
    let path = FSPathURLResource(url: HelloFileSystem.stubURL, writable: false)
    let generic = FSGenericURLResource(url: URL(string: "macdroidbridge://hello")!)
    final class Scope {
        var starts = 0, stops = 0, validations = 0
        var allowed = true, valid = true
        var access: HelloFileSystem.PathAccess {
            .init(start: { _ in self.starts += 1; return self.allowed },
                  stop: { _ in self.stops += 1 },
                  validate: { _ in self.validations += 1; if !self.valid { throw POSIXError(.EINVAL) } })
        }
    }
    func checkError(_ code: Int32, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual(($0 as NSError).code, Int(code)) }
    }
    func testPathAllowlist() {
        XCTAssertTrue(HelloFileSystem.accepts(path))
        XCTAssertFalse(HelloFileSystem.accepts(FSPathURLResource(url: HelloFileSystem.stubURL, writable: true)))
        for string in ["file:///etc/passwd", "file:///private/tmp/other.stub", "file:///tmp/macdroidbridge-m0a.stub", "file:///private/tmp/macdroidbridge-m0a.stub/", "file:///private/tmp/macdroidbridge-m0a.stub?x=1", "file:///private/tmp/macdroidbridge-m0a.stub#x", "file://localhost/private/tmp/macdroidbridge-m0a.stub", "file:///private/tmp/../tmp/macdroidbridge-m0a.stub"] {
            XCTAssertFalse(HelloFileSystem.accepts(FSPathURLResource(url: URL(string: string)!, writable: false)), string)
        }
        XCTAssertFalse(HelloFileSystem.accepts(FSGenericURLResource(url: HelloFileSystem.stubURL)))
    }
    func testProbeBalancesScopeAndRejectsFailure() {
        let scope = Scope(), fs = HelloFileSystem(access: Scope().access)
        let scopedFS = HelloFileSystem(access: scope.access)
        scopedFS.probeResource(resource: path) { result, error in
            XCTAssertNil(error); XCTAssertEqual(result?.result, .usable)
        }
        XCTAssertEqual(scope.starts, 1); XCTAssertEqual(scope.stops, 1)
        scope.valid = false
        scopedFS.probeResource(resource: path) { result, error in
            XCTAssertNil(error); XCTAssertEqual(result?.result, .notRecognized)
        }
        XCTAssertEqual(scope.stops, 2)
        scope.allowed = false
        scopedFS.probeResource(resource: path) { result, _ in XCTAssertEqual(result?.result, .notRecognized) }
        XCTAssertEqual(scope.starts, 3); XCTAssertEqual(scope.stops, 2)
        fs.probeResource(resource: generic) { result, _ in XCTAssertEqual(result?.result, .usable) }
    }
    func testLoadUnloadAndSameMemoryTree() throws {
        let scope = Scope(), fs = HelloFileSystem(access: Scope().access)
        let scopedFS = HelloFileSystem(access: scope.access)
        let volume = try scopedFS.load(path)
        let genericVolume = try fs.load(generic)
        XCTAssertEqual(try volume.tree.read(5, offset: 0, length: 100), try genericVolume.tree.read(5, offset: 0, length: 100))
        XCTAssertEqual(try volume.tree.entries(in: 2, cookie: 0, includeDots: false).map(\.name), ["Documents", "README.txt"])
        XCTAssertEqual(scope.starts, 1); XCTAssertEqual(scope.stops, 0)
        checkError(EBUSY) { _ = try scopedFS.load(path) }
        checkError(EINVAL) { try scopedFS.unload(generic) }
        XCTAssertEqual(scope.stops, 0)
        try scopedFS.unload(FSPathURLResource(url: HelloFileSystem.stubURL, writable: false))
        XCTAssertEqual(scope.stops, 1)
        checkError(EINVAL) { try scopedFS.unload(path) }
        XCTAssertEqual(scope.stops, 1)
        try fs.unload(generic)
        _ = try scopedFS.load(generic)
        try scopedFS.unload(generic)
        XCTAssertEqual(scope.starts, 1)
    }
    func testLoadFailuresAndDeinitCleanup() throws {
        let scope = Scope()
        var fs: HelloFileSystem? = HelloFileSystem(access: scope.access)
        checkError(ENOTSUP) { _ = try fs!.load(path, arguments: ["-f"]) }
        checkError(EINVAL) { _ = try fs!.load(FSGenericURLResource(url: URL(string: "macdroidbridge://other")!)) }
        XCTAssertEqual(scope.starts, 0)
        scope.allowed = false
        checkError(EACCES) { _ = try fs!.load(path) }
        XCTAssertEqual(scope.stops, 0)
        scope.allowed = true; scope.valid = false
        checkError(EINVAL) { _ = try fs!.load(path) }
        XCTAssertEqual(scope.stops, 1)
        scope.valid = true
        _ = try fs!.load(path)
        fs = nil
        XCTAssertEqual(scope.starts, 3); XCTAssertEqual(scope.stops, 2)
    }
    func testRealStubMetadataValidation() throws {
        // Unique fixtures exercise metadata checks; production allowlisting remains fixed.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("stub").resolvingSymlinksInPath()
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o600]))
        try HelloFileSystem.validateStub(file)
        try Data([1]).write(to: file)
        checkError(EINVAL) { try HelloFileSystem.validateStub(file) }
        try Data().write(to: file)
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        checkError(EINVAL) { try HelloFileSystem.validateStub(file) }
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        checkError(EINVAL) { try HelloFileSystem.validateStub(link) }
        checkError(EINVAL) { try HelloFileSystem.validateStub(directory) }
        checkError(ENOENT) { try HelloFileSystem.validateStub(directory.appendingPathComponent("missing")) }
        let hardlink = directory.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: file, to: hardlink)
        checkError(EINVAL) { try HelloFileSystem.validateStub(file) }
    }
}
