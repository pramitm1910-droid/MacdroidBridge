import Foundation
import FSKit

final class HelloItem: FSItem {
    let nodeID: UInt64
    init(_ id: UInt64) { nodeID = id; super.init() }
}

final class HelloVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations {
    let tree = MemoryTree()
    private let attributeLock = NSLock()
    private let items: [UInt64: HelloItem] = [2: HelloItem(2), 3: HelloItem(3), 4: HelloItem(4), 5: HelloItem(5)]
    var rootItem: FSItem { items[2]! }
    init() { super.init(volumeID: FSVolume.Identifier(uuid: HelloFileSystem.volumeUUID), volumeName: FSFileName(string: "MacdroidBridge")) }
    private func node(_ item: FSItem) throws -> MemoryTree.Node {
        guard let item = item as? HelloItem, items[item.nodeID] === item else { throw posix(ESTALE) }
        return try tree.node(item.nodeID)
    }
    func attributes(for node: MemoryTree.Node) -> FSItem.Attributes {
        attributeLock.lock(); defer { attributeLock.unlock() }
        let a = FSItem.Attributes()
        a.type = node.isDirectory ? .directory : .file
        a.fileID = FSItem.Identifier(rawValue: node.id)!
        a.parentID = FSItem.Identifier(rawValue: node.parent)!
        a.mode = node.isDirectory ? 0o555 : 0o444
        a.uid = getuid(); a.gid = getgid(); a.linkCount = 1
        a.size = UInt64(node.contents?.count ?? 0); a.allocSize = a.size
        a.flags = 0
        a.inhibitKernelOffloadedIO = true
        let timestamp = timespec(tv_sec: 1_700_000_000, tv_nsec: 0)
        a.birthTime = timestamp; a.modifyTime = timestamp; a.changeTime = timestamp; a.accessTime = timestamp; a.addedTime = timestamp
        return a
    }
    // On 26.0–26.3 use the manual -r mount option; mutations always return EROFS.
    @available(macOS 26.4, *)
    var requestedMountOptions: FSVolume.MountOptions { get { .readOnly } set {} }
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64.max >> 1 }
    var maximumXattrSize: Int { 0 }
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities()
        c.caseFormat = .sensitive
        return c
    }
    var volumeStatistics: FSStatFSResult {
        let s = FSStatFSResult(fileSystemTypeName: "mdbhello")
        s.blockSize = 4096; s.ioSize = 4096; s.totalBlocks = 2; s.usedBlocks = 2
        s.totalFiles = 4
        return s
    }
    func activate(options: FSTaskOptions, replyHandler: @escaping (FSItem?, Error?) -> Void) { replyHandler(rootItem, nil) }
    func deactivate(options: FSDeactivateOptions, replyHandler: @escaping (Error?) -> Void) { replyHandler(nil) }
    func mount(options: FSTaskOptions, replyHandler: @escaping (Error?) -> Void) { replyHandler(nil) }
    func unmount(replyHandler: @escaping () -> Void) { replyHandler() }
    func synchronize(flags: FSSyncFlags, replyHandler: @escaping (Error?) -> Void) { replyHandler(nil) }
    func reclaimItem(_ item: FSItem, replyHandler: @escaping (Error?) -> Void) { replyHandler(nil) }
    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        do { replyHandler(attributes(for: try node(item)), nil) } catch { replyHandler(nil, error) }
    }
    func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        do {
            guard let string = name.string else { throw posix(EILSEQ) }
            let found = try tree.lookup(string, in: node(directory).id)
            replyHandler(items[found.id], FSFileName(string: string == "." || string == ".." ? string : found.name), nil)
        } catch { replyHandler(nil, nil, error) }
    }
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes request: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler: @escaping (FSDirectoryVerifier, Error?) -> Void) {
        do {
            guard verifier.rawValue == 0 || verifier.rawValue == 1 else { throw posix(4506) }
            for entry in try tree.entries(in: node(directory).id, cookie: cookie.rawValue, includeDots: request == nil) {
                if !packer.packEntry(name: FSFileName(string: entry.name), itemType: entry.node.isDirectory ? .directory : .file, itemID: FSItem.Identifier(rawValue: entry.node.id)!, nextCookie: FSDirectoryCookie(rawValue: entry.nextCookie), attributes: request == nil ? nil : attributes(for: entry.node)) { break }
            }
            replyHandler(FSDirectoryVerifier(rawValue: 1), nil)
        } catch { replyHandler(verifier, error) }
    }
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler: @escaping (Int, Error?) -> Void) {
        do {
            let bytes = try tree.read(node(item).id, offset: offset, length: min(length, buffer.length))
            _ = buffer.withUnsafeMutableBytes { destination in bytes.copyBytes(to: destination) }
            replyHandler(bytes.count, nil)
        } catch { replyHandler(0, error) }
    }
    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler: @escaping (Int, Error?) -> Void) { replyHandler(0, posix(EROFS)) }
    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) { replyHandler(nil, posix(EROFS)) }
    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest, replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) { replyHandler(nil, nil, posix(EROFS)) }
    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest, linkContents: FSFileName, replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) { replyHandler(nil, nil, posix(EROFS)) }
    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem, replyHandler: @escaping (FSFileName?, Error?) -> Void) { replyHandler(nil, posix(EROFS)) }
    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler: @escaping (Error?) -> Void) { replyHandler(posix(EROFS)) }
    func renameItem(_ item: FSItem, inDirectory source: FSItem, named name: FSFileName, to destinationName: FSFileName, inDirectory destination: FSItem, overItem: FSItem?, replyHandler: @escaping (FSFileName?, Error?) -> Void) { replyHandler(nil, posix(EROFS)) }
    func readSymbolicLink(_ item: FSItem, replyHandler: @escaping (FSFileName?, Error?) -> Void) { replyHandler(nil, posix(EINVAL)) }
}
