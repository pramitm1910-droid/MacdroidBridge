import Foundation

/// One session, one fresh storage discovery, one root query. Never reads content.
public enum MTPRootListing {
    public struct Result {
        public let storageID: UInt32
        public let totalHandles: Int
        public let entries: [MTPObjectInfo]
        public var complete: Bool { entries.count == totalHandles }
    }

    public static func run(device: MTPDevice, emit: (String) -> Void = { print($0) }) throws -> Result {
        var opened = false
        var closeAttempted = false
        defer {
            if opened && !closeAttempted {
                do { try device.closeSession(); emit("Root cleanup: CloseSession succeeded") }
                catch { emit("Root cleanup: CloseSession unavailable/failed; releasing transport: \(error)") }
            }
            device.shutdown()
        }
        try device.openSession()
        opened = true
        let ids = try device.getStorageIDs()
        guard !ids.isEmpty else { throw MTPParseError.malformed("Valid empty-success storage response; root listing unavailable") }
        guard ids.count <= 16, Set(ids).count == ids.count,
              ids.allSatisfy({ $0 != 0 && $0 != 0xFFFFFFFF }) else {
            throw MTPParseError.malformed("Ambiguous or invalid storage list")
        }
        // Fixed RAM (MTP 0x0003) identifies non-removable writable storage.
        // Do not select by a historical ID or localized description.
        let storages = try ids.map { try device.getStorageInfo(storageID: $0) }
        let internalStores = storages.filter { $0.storageType == 3 }
        guard internalStores.count == 1 else {
            throw MTPParseError.malformed("No unique fixed internal storage returned")
        }
        let storage = internalStores[0]
        let handles = try device.getRootObjectHandles(storageID: storage.storageID)
        var entries: [MTPObjectInfo] = []
        for handle in handles.prefix(32) {
            let info = try device.getRootObjectInfo(objectHandle: handle)
            guard info.storageID == storage.storageID, info.parentObject == 0 else {
                throw MTPParseError.malformed("Object does not belong to selected storage root")
            }
            entries.append(info)
        }
        closeAttempted = true
        try device.closeSession()
        return Result(storageID: storage.storageID, totalHandles: handles.count, entries: entries)
    }
}
