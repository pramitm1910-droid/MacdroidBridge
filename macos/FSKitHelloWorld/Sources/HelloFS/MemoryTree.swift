import Foundation
import Darwin

func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }

/// Immutable contents; IDs remain stable for every activation of this prototype.
struct MemoryTree {
    struct Node {
        let id: UInt64
        let parent: UInt64
        let name: String
        let contents: Data?
        let children: [UInt64]
        var isDirectory: Bool { contents == nil }
    }
    let nodes: [UInt64: Node] = [
        2: Node(id: 2, parent: 2, name: "MacdroidBridge", contents: nil, children: [3, 4]),
        3: Node(id: 3, parent: 2, name: "Documents", contents: nil, children: [5]),
        4: Node(id: 4, parent: 2, name: "README.txt", contents: Data("MacdroidBridge FSKit Hello World\nRead-only, in-memory filesystem. No USB or MTP connection.\n".utf8), children: []),
        5: Node(id: 5, parent: 3, name: "hello.txt", contents: Data("Hello from native FSKit!\n".utf8), children: [])
    ]
    func node(_ id: UInt64) throws -> Node {
        guard let node = nodes[id] else { throw posix(ENOENT) }
        return node
    }
    func lookup(_ name: String, in id: UInt64) throws -> Node {
        let directory = try node(id)
        guard directory.isDirectory else { throw posix(ENOTDIR) }
        if name == "." { return directory }
        if name == ".." { return try node(directory.parent) }
        guard let child = directory.children.compactMap({ nodes[$0] }).first(where: { $0.name == name }) else { throw posix(ENOENT) }
        return child
    }
    struct Entry { let name: String; let node: Node; let nextCookie: UInt64 }
    // Fixed slot numbering keeps cookies consistent with and without dot entries.
    func entries(in id: UInt64, cookie: UInt64, includeDots: Bool) throws -> [Entry] {
        let directory = try node(id)
        guard directory.isDirectory else { throw posix(ENOTDIR) }
        let end = UInt64(directory.children.count + 2)
        guard cookie <= end else { throw posix(4506) } // FSKit invalidDirectoryCookie, POSIX domain per SDK.
        var entries: [Entry] = []
        for slot in Int(cookie)..<Int(end) {
            if slot < 2 {
                if includeDots { entries.append(Entry(name: slot == 0 ? "." : "..", node: try node(slot == 0 ? id : directory.parent), nextCookie: UInt64(slot + 1))) }
            } else {
                let child = try node(directory.children[slot - 2])
                entries.append(Entry(name: child.name, node: child, nextCookie: UInt64(slot + 1)))
            }
        }
        return entries
    }
    func read(_ id: UInt64, offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0 else { throw posix(EINVAL) }
        guard let bytes = try node(id).contents else { throw posix(EISDIR) }
        guard offset < bytes.count else { return Data() }
        let start = Int(offset)
        return bytes.subdata(in: start..<(start + min(length, bytes.count - start)))
    }
}
