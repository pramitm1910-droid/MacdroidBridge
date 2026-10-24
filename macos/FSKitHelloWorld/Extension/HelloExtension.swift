import FSKit

@main
struct HelloExtension: UnaryFileSystemExtension {
    let fileSystem = HelloFileSystem()
}
