import Foundation

/// Explicit, idempotent release. No deinit-based release: losing a live lease must
/// not authorize destruction of resources that an asynchronous request still uses.
final class MTPAsyncResourceLease {
    private let lock = NSLock()
    private var retained: [AnyObject]
    private var releaseAction: (() -> Void)?

    init(retaining objects: [AnyObject], release: @escaping () -> Void) {
        retained = objects
        releaseAction = release
    }

    func release() {
        lock.lock()
        let action = releaseAction
        releaseAction = nil
        let objects = retained
        retained = []
        lock.unlock()
        withExtendedLifetime(objects) { action?() }
    }
}
