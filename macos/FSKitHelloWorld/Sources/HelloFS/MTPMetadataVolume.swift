import Foundation
import FSKit

/// FSKit callback adapter for metadata-only Android nodes. The volume can enumerate
/// and report known attributes, but deliberately cannot read bytes or mutate storage.
final class MTPMetadataVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations {
    private final class Item: FSItem {
        let fileID: UInt64
        init(_ fileID: UInt64) { self.fileID = fileID; super.init() }
    }
    private let adapter: MTPMetadataAdapter
    private let itemLock = NSRecursiveLock()
    private var items: [UInt64: Item] = [:]
    var rootItem: FSItem { item(2) }
    var contentReadError: Error { posix(EOPNOTSUPP) }
    var activationError: Error { posix(EOPNOTSUPP) }

    init(adapter: MTPMetadataAdapter, volumeUUID: UUID) {
        self.adapter = adapter
        super.init(volumeID: FSVolume.Identifier(uuid: volumeUUID), volumeName: FSFileName(string: "Android"))
    }
    private func item(_ id: UInt64) -> Item {
        itemLock.lock(); defer { itemLock.unlock() }
        if let value = items[id] { return value }
        let value = Item(id); items[id] = value; return value
    }
    private func node(_ item: FSItem) throws -> MTPFilesystemNode {
        guard let item = item as? Item else { throw posix(ESTALE) }
        return try adapter.node(item.fileID)
    }
    private func attributes(_ node: MTPFilesystemNode) throws -> FSItem.Attributes {
        let result = FSItem.Attributes()
        result.type = node.kind == .directory || node.kind == .storage || node.kind == .volumeRoot ? .directory : .file
        result.fileID = FSItem.Identifier(rawValue: node.fileID)!
        result.parentID = FSItem.Identifier(rawValue: node.parentID)!
        result.mode = result.type == .directory ? 0o555 : 0o444
        result.uid = getuid(); result.gid = getgid(); result.linkCount = 1
        result.size = try adapter.attributesSize(of: node); result.allocSize = result.size
        result.inhibitKernelOffloadedIO = true
        return result
    }
    @available(macOS 26.4, *) var requestedMountOptions: FSVolume.MountOptions { get { .readOnly } set {} }
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64.max >> 1 }
    var maximumXattrSize: Int { 0 }
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let result = FSVolume.SupportedCapabilities(); result.caseFormat = .sensitive; return result
    }
    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "mtpmetadata")
        result.blockSize = 4096; result.ioSize = 4096; result.totalBlocks = 0; result.usedBlocks = 0
        result.totalFiles = 0; return result
    }
    func activate(options: FSTaskOptions, replyHandler: @escaping (FSItem?, Error?) -> Void) { replyHandler(nil, activationError) }
    func deactivate(options: FSDeactivateOptions, replyHandler: @escaping (Error?) -> Void) { replyHandler(nil) }
    func mount(options: FSTaskOptions, replyHandler: @escaping (Error?) -> Void) { replyHandler(nil) }
    func unmount(replyHandler: @escaping () -> Void) { adapter.cancel(); replyHandler() }
    func synchronize(flags: FSSyncFlags, replyHandler: @escaping (Error?) -> Void) { replyHandler(nil) }
    func reclaimItem(_ item: FSItem, replyHandler: @escaping (Error?) -> Void) { replyHandler(nil) }
    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        do { replyHandler(try attributes(node(item)), nil) } catch { replyHandler(nil, error) }
    }
    func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        do {
            guard let name = name.string else { throw posix(EILSEQ) }
            let found = try adapter.lookup(name, in: node(directory))
            replyHandler(item(found.fileID), FSFileName(string: name), nil)
        } catch { replyHandler(nil, nil, error) }
    }
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes request: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler: @escaping (FSDirectoryVerifier, Error?) -> Void) {
        do {
            guard verifier.rawValue == 0 || verifier.rawValue == 1 else { throw posix(Int32(FSError.Code.invalidDirectoryCookie.rawValue)) }
            let parent = try node(directory)
            let contents = try adapter.children(of: parent)
            let end = UInt64(contents.count + 2)
            guard cookie.rawValue <= end else { throw posix(Int32(FSError.Code.invalidDirectoryCookie.rawValue)) }
            for slot in Int(cookie.rawValue)..<Int(end) {
                if slot < 2 {
                    if request == nil {
                        let dot = slot == 0 ? parent : try adapter.node(parent.parentID)
                        if !packer.packEntry(name: FSFileName(string: slot == 0 ? "." : ".."), itemType: .directory,
                            itemID: FSItem.Identifier(rawValue: dot.fileID)!, nextCookie: FSDirectoryCookie(rawValue: UInt64(slot + 1)), attributes: nil) { break }
                    }
                } else {
                    let child = contents[slot - 2]
                    let attrs = try request.map { _ in try attributes(child) }
                    let type: FSItem.ItemType = child.kind == .directory || child.kind == .storage ? .directory : .file
                    if !packer.packEntry(name: FSFileName(string: child.name), itemType: type,
                        itemID: FSItem.Identifier(rawValue: child.fileID)!, nextCookie: FSDirectoryCookie(rawValue: UInt64(slot + 1)), attributes: attrs) { break }
                }
            }
            replyHandler(FSDirectoryVerifier(rawValue: 1), nil)
        } catch { replyHandler(verifier, error) }
    }
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler: @escaping (Int, Error?) -> Void) {
        do { _ = try node(item); replyHandler(0, contentReadError) } catch { replyHandler(0, error) }
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
