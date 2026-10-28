/// Transaction IDs used by one MTP session. OpenSession uses transaction ID 0;
/// regular operations allocate sequential IDs beginning at 1.
public struct MTPTransactionIDAllocator {
    public static let openSessionTransactionID: UInt32 = 0

    private var nextID: UInt32

    public init(startingAt firstID: UInt32 = 1) {
        precondition(firstID != 0, "Transaction ID 0 is reserved for OpenSession")
        nextID = firstID
    }

    public mutating func allocate() -> UInt32 {
        let allocatedID = nextID
        nextID = allocatedID == UInt32.max ? 1 : allocatedID + 1
        return allocatedID
    }
}
