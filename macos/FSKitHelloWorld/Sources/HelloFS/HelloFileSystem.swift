import Foundation
import FSKit
import Darwin
import MTPMetadataContracts

final class HelloFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    static let volumeUUID = UUID(uuidString: "37A73867-96C0-456C-B465-CB775589F02A")!
    // Deliberately fixed: callers cannot nominate arbitrary files or directories.
    static let stubURL = URL(fileURLWithPath: "/private/tmp/macdroidbridge-m0a.stub")
    struct PathAccess {
        var start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
        var stop: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
        var validate: (URL) throws -> Void = HelloFileSystem.validateStub
    }
    private let access: PathAccess
    /// Injection point for a future XPC client. The shipped extension leaves this nil.
    private let metadataSourceFactory: (() throws -> MTPMetadataSource)?
    private let lock = NSLock()
    private var loaded: FSResource?
    init(access: PathAccess = PathAccess(), metadataSourceFactory: (() throws -> MTPMetadataSource)? = nil) {
        self.access = access; self.metadataSourceFactory = metadataSourceFactory; super.init()
    }
    deinit {
        if let path = loaded as? FSPathURLResource { access.stop(path.url) }
    }

    // Syntax only; filesystem metadata is checked after acquiring security scope.
    static func accepts(_ resource: FSResource) -> Bool {
        if let path = resource as? FSPathURLResource {
            return !path.isWritable && path.url.absoluteString == stubURL.absoluteString
        }
        guard let resource = resource as? FSGenericURLResource else { return false }
        let url = resource.url
        return url.scheme?.lowercased() == "macdroidbridge" && url.host == "hello"
            && (url.path.isEmpty || url.path == "/") && url.user == nil && url.password == nil
            && url.port == nil && url.query == nil && url.fragment == nil
    }
    static func validateStub(_ url: URL) throws {
        // No file contents are opened. lstat rejects symlinks, directories and devices.
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posix(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size == 0,
              info.st_uid == geteuid(), info.st_nlink == 1,
              (info.st_mode & 0o777) == 0o600,
              url.resolvingSymlinksInPath().path == url.path else { throw posix(EINVAL) }
    }
    private func acquire(_ resource: FSResource) throws {
        guard Self.accepts(resource) else { throw posix(EINVAL) }
        if let path = resource as? FSPathURLResource {
            guard access.start(path.url) else { throw posix(EACCES) }
            do { try access.validate(path.url) }
            catch { access.stop(path.url); throw error }
        }
    }
    private func release(_ resource: FSResource) {
        if let path = resource as? FSPathURLResource { access.stop(path.url) }
    }
    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, Error?) -> Void) {
        do {
            try acquire(resource)
            release(resource)
            replyHandler(.usable(name: "MacdroidBridge", containerID: FSContainerIdentifier(uuid: Self.volumeUUID)), nil)
        } catch {
            replyHandler(.notRecognized, nil)
        }
    }
    // These seams also exercise the exact callback implementation without constructing
    // OS-owned FSTaskOptions (which has no public initializer in the 26.5 SDK).
    func load(_ resource: FSResource, arguments: [String] = []) throws -> FSVolume {
        lock.lock(); defer { lock.unlock() }
        guard loaded == nil else { throw posix(EBUSY) }
        guard !arguments.contains("-f") else { throw posix(ENOTSUP) }
        try acquire(resource)
        let volume: FSVolume
        if let metadataSourceFactory {
            let source = try metadataSourceFactory()
            let adapter = MTPMetadataAdapter(source: source)
            volume = MTPMetadataVolume(adapter: adapter, volumeUUID: source.snapshot.generation)
        } else {
            volume = HelloVolume()
        }
        loaded = resource
        containerStatus = .ready
        return volume
    }
    func unload(_ resource: FSResource) throws {
        lock.lock(); defer { lock.unlock() }
        guard let current = loaded else { throw posix(EINVAL) }
        let matches: Bool
        if let a = current as? FSPathURLResource, let b = resource as? FSPathURLResource {
            matches = a.url == b.url && a.isWritable == b.isWritable
        } else if let a = current as? FSGenericURLResource, let b = resource as? FSGenericURLResource {
            matches = a.url == b.url
        } else { matches = false }
        guard matches else { throw posix(EINVAL) }
        release(current)
        loaded = nil
        containerStatus = .notReady(status: posix(ENOTCONN))
    }
    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, Error?) -> Void) {
        do { replyHandler(try load(resource, arguments: options.taskOptions), nil) }
        catch { replyHandler(nil, error) }
    }
    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (Error?) -> Void) {
        do { try unload(resource); replyHandler(nil) }
        catch { replyHandler(error) }
    }
}
