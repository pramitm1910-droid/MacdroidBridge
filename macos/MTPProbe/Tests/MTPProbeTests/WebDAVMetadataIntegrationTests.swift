import Foundation
import XCTest
@testable import MTPProbeLib
import MTPMetadataContracts

final class WebDAVMetadataIntegrationTests: XCTestCase {
    func testRootHandleAndLateBatchDirectoryNavigation() throws {
        let session = MTPFolderBrowserTests.Synthetic()
        session.root = Array(2...45) + [1]
        let browser = MTPFolderBrowser()
        _ = try browser.start(session)
        defer { try? browser.close() }
        let source = MTPFolderBrowserMetadataSource(browser: browser)
        let partial = try source.enter(storage: 0x20002, path: [])
        XCTAssertEqual(partial.directoryHandle, 0)
        let complete = try source.continueListing()
        let directory = try XCTUnwrap(complete.entries.first { $0.isDirectory })
        let nested = try source.enter(storage: 0x20002, path: [directory.identity])
        XCTAssertEqual(nested.state, .complete)
        XCTAssertEqual(nested.directoryHandle, 1)
        XCTAssertEqual(nested.entries.count, 2)
    }

    func testActualSwiftBrowserThroughJSONToWebDAVOffline() throws {
        let session = MTPFolderBrowserTests.Synthetic()
        session.root = Array(2...45) + [1]
        session.names = [2: "duplicate", 3: "duplicate", 4: "写真"]
        session.size = UInt32.max
        let browser = MTPFolderBrowser()
        _ = try browser.start(session)
        defer { try? browser.close() }
        let service = MTPMetadataService(source: MTPFolderBrowserMetadataSource(browser: browser))
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WebDAVPrototype/tests/swift_metadata_roundtrip.py")
        let process = Process(), requests = Pipe(), replies = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path]
        process.standardOutput = requests; process.standardInput = replies
        process.standardError = FileHandle.standardError
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if process.isRunning { process.terminate() } }
        defer { if process.isRunning { process.terminate() } }
        var line = Data(), count = 0
        while let byte = try requests.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) {
                let reply = try service.receive(line)
                try replies.fileHandleForWriting.write(contentsOf: reply + Data([10]))
                line.removeAll(keepingCapacity: true); count += 1
            } else {
                line.append(byte)
                guard line.count <= 32768 else { XCTFail("request cap"); process.terminate(); break }
            }
        }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertGreaterThan(count, 10)
        XCTAssertGreaterThan(session.infos, 45)
        XCTAssertEqual(session.openCount, 1)
    }

    func testServiceAdmissionBoundAndCancellationBypassesOperationLock() throws {
        let session = MTPFolderBrowserTests.Synthetic()
        let browser = MTPFolderBrowser(); _ = try browser.start(session)
        let service = MTPMetadataService(source: MTPFolderBrowserMetadataSource(browser: browser), maximumPending: 1)
        let initialize = MTPIPCRequest(operation: .initialize)
        let reply = try JSONDecoder().decode(MTPIPCResponse.self, from: service.receive(JSONEncoder().encode(initialize)))
        var request = MTPIPCRequest(operation: .directory)
        request.session = reply.session; request.sequence = 1
        request.generation = reply.snapshot?.generation; request.namespace = reply.snapshot?.namespace
        request.storage = 0x20002
        let data = try JSONEncoder().encode(request)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = expectation(description: "in-flight call invalidated")
        session.onInfo = { entered.signal(); _ = release.wait(timeout: .now() + 3) }
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                let response = try JSONDecoder().decode(MTPIPCResponse.self, from: service.receive(data))
                XCTAssertNotNil(response.error)
                XCTAssertNil(response.snapshot)
            } catch { XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try service.receive(data)) { XCTAssertEqual($0 as? MTPIPCError, .busy) }
        service.invalidate(session: reply.session, cancelled: true)
        XCTAssertEqual(browser.snapshot.phase, .cancelled)
        release.signal()
        wait(for: [done], timeout: 4)
    }
}
