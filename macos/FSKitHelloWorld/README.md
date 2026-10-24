# MacdroidBridge — FSKit M0 / M0A

An isolated native read-only filesystem for **macOS 26.0 and later**. The Xcode
project has a SwiftUI host application and an embedded ExtensionKit filesystem
extension. It imports no production modules and performs no USB, MTP, device,
network, or application-defined XPC operations. FSKit itself supplies the OS
communication infrastructure. Running the host does not mount anything.

```text
MacdroidBridge/
├── Documents/
│   └── hello.txt
└── README.txt
```

`hello.txt` contains `Hello from native FSKit!` followed by a newline. The README
explains that the volume is in memory and read-only. All data and names are fixed.

## Build and tests

From this directory:

```sh
bash verify.sh
```

The script builds unsigned bundles, separately compiles and links both complete
executables against the macOS 26.5 SDK, and runs twelve XCTest tests with the native
SwiftPM build system. It creates a fresh `/private/tmp/macdroidbridge-m0.*`
directory for artifacts and logs. `BUILD_ROOT` and `SDK26` may override these paths.
It does not launch the host, enable the extension, sign, mount, or unmount.

The verification run passed, including the SDK 26.5 compiler/linker checks and all twelve tests.
The Xcode project can also be opened directly:
`MacdroidBridgeHello.xcodeproj`, scheme `MacdroidBridgeHello`.
The deployment target is 26.0 for both targets; the existing Personal Team assignment is retained; signing is disabled by verify.sh.

**Toolchain distinction:** Xcode 27.1's registered SDK is macOS 27.0. Its bundle
build fails when pointed at the external CLT macOS 26.5 SDK during Info.plist task
processing (`SDK lookup failed for canonical name: macosx26.5`). Consequently the
Xcode bundle build uses its registered SDK. The direct compiler/linker checks and
SwiftPM tests explicitly use `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.
This verifies the real source against 26.5 without modifying Xcode's installation.
SwiftPM's default Xcode backend did not honor the custom SDK compiler arguments;
`--build-system native` is intentional.

## FSKit implementation and SDK evidence

Declarations were inspected in the 26.5 SDK's `FSKit.framework/Headers` and
`Modules/FSKit.swiftmodule/arm64e-apple-macos.swiftinterface`. Successful compilation
checks every concrete protocol signature in `Sources/HelloFS`.

- `UnaryFileSystemExtension` supplies a delegate conforming to
  `FSUnaryFileSystem` and `FSUnaryFileSystemOperations`.
- The generic route accepts `FSGenericURLResource(url:)` for
  `macdroidbridge://hello` (optional trailing slash). Credentials, ports, query
  parameters, fragments and additional paths are rejected. Probe reports usable;
  load constructs the volume and clears the container error state.
- `FSVolume.Operations` implements activation/deactivation, mount/unmount callbacks,
  lookup, attributes, reclaim, synchronization, enumeration and required mutations.
  These callbacks never invoke system mount/unmount commands.
- `FSVolume.ReadWriteOperations.read(from:at:length:into:replyHandler:)` uses
  `FSMutableFileDataBuffer.withUnsafeMutableBytes`. No kernel-offloaded protocol
  is implemented, and attributes explicitly set `inhibitKernelOffloadedIO = true`.
- Reads clamp at EOF and buffer capacity; reads at/past EOF return zero bytes.
  Negative offsets/lengths are rejected. Required mutations return POSIX `EROFS`.
  Modes are 0555 for directories and 0444 for files. macOS 26.4+ also receives
  `requestedMountOptions = .readOnly`; the manual command includes `-r` for all versions.
- Stable item identities are scoped to the volume. Foreign items return `ESTALE`.
  Attribute snapshots are serialized with a lock. The tree is immutable, so reclaim
  and teardown need no I/O or mutable tree cleanup; objects die with the volume.
- Enumeration reserves slots 0 and 1 for `.` and `..`; attributed enumerations omit
  those entries while preserving cookie numbering. A cookie denotes the next slot;
  the terminal cookie yields no entries. Packing stops immediately when the buffer
  refuses an entry. The immutable directory verifier is 1; invalid cookies/verifiers
  return code `FSError.Code.invalidDirectoryCookie` in the POSIX domain as specified
  by the installed enumeration header.
- `FSClient.shared.fetchInstalledExtensions` is available on 26 for discovery.
  **`FSClient.mountSingleVolume` is macOS 27-only and is not used.**

Tests cover exact contents, case-sensitive lookup and errors, parent lookups,
partial reads and EOF/overflow boundaries, cookie resumption and invalid cookies,
resource probing, adapter lookup/attributes/foreign items, and every required
mutation callback. Tests do not instantiate OS-owned directory packers or data
buffers and do not establish end-to-end kernel/Finder behavior.

The ExtensionKit product type and metadata follow the installed Xcode FSKit and
ExtensionKit templates. The embedded product is under
`MacdroidBridgeHello.app/Contents/Extensions/MacdroidBridgeFS.appex`.
`EXAppExtensionAttributes` declares `com.apple.fskit.fsmodule`, short name
`mdbhello`, generic URL support and `FSSupportedSchemes = [macdroidbridge]`.
Path URL support and required security-scoped path URLs are enabled. Block and server URL resource flags remain false. Both targets declare App
Sandbox; only the extension declares `com.apple.developer.fskit.fsmodule`.
**Declarations do not grant signing or provisioning authorization.**

Sources: [FSKit](https://developer.apple.com/documentation/fskit),
[generic URL resources and supported schemes](https://developer.apple.com/documentation/fskit/fsgenericurlresource),
[FSKit entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule),
and the installed `mount(8)` manual (`-F`, `-t`, `-r`).

## Signing blocker — no retry in M0A

Xcode reported: “Personal development teams, including PRAMIT M, do not support
the FSKit Module capability.” The current team assignment, bundle identifiers,
FSKit entitlement, sandbox declarations and 26.0 deployment target are unchanged.
Unsigned compilation and tests do not resolve provisioning. Eligible development
signing, separately authorized extension activation and an actual mount experiment
are still required before claiming Finder integration. Do not retry provisioning
with this Personal Team or remove the entitlement.

## Separately authorized manual mount experiment — unverified

The installed macOS 26 `mount(8)` documents FSKit selection with `-F`, type selection
with `-t`, and read-only mounting with `-r`. Apple documents generic URL resources
and scheme declarations. **A complete documented macOS 26 custom-URL invocation
has not been established; the following is a candidate test, not a proven mount
procedure.** Do not run it until separately authorized after signing and enabling.

Use a new, empty, user-owned mountpoint. Do not replace or mount over existing data:

```sh
mkdir "$HOME/MacdroidBridge-M0"
/sbin/mount -F -t mdbhello -r 'macdroidbridge://hello' "$HOME/MacdroidBridge-M0"
```

If this command fails, record its exact output and FSKit logs; do not retry with
security changes, private APIs, or a macOS 27-only API on macOS 26.

Only after a successful mount, inspect the mountpoint in Finder using Go → Go to
Folder. Confirm `Documents/hello.txt` opens with the expected text and `README.txt`
is present. Record separately whether the volume appears in Finder's sidebar;
mount success does not establish sidebar visibility. Terminal reads and a write
attempt confined to this test volume can additionally verify read-only behavior.

For a separately authorized safe unmount, close Finder previews and applications
using the test files, move terminals outside the mountpoint, then:

```sh
/sbin/umount "$HOME/MacdroidBridge-M0"
```

If busy, close the remaining users and retry normally; do not force unmount.

## M0A path resource

`FSPathURLResource(url:writable:)` accepts only the exact URL
`file:///private/tmp/macdroidbridge-m0a.stub`, with `writable: false`. This is a
fixed test fixture location, not a configurable route to user documents. A future
authorized caller must deliberately create an **empty regular file**, owned by the
extension's effective user, mode **0600**, with one hard link. The fixture is not
created by the extension or these instructions. Symlinks (including parent path
aliases), directories, nonempty files, writable resources, alternate URLs and
other resource classes are rejected. Metadata is checked without reading contents.
Tests create unique disposable fixtures and never touch the fixed production path.

Both routes construct the same `HelloVolume` and immutable `MemoryTree`. The stub
is only an admission token: it supplies no file data and represents no Android
storage. No USB, MTP or XPC integration is added. Changing or removing the stub
after load cannot alter the in-memory volume; no backing descriptor is retained.

Probe acquires security scope, validates metadata and releases scope before its
callback. Load retains the original resource and its successful scope until a
matching unload (or filesystem deinitialization). Failed acquisition returns
`EACCES` on load; metadata failure releases scope immediately. Probe reports
unrecognized on either failure. Duplicate loads return `EBUSY`; mismatched or
repeated unloads return `EINVAL` without releasing another resource's scope.
Force-load (`-f`) is unsupported (`ENOTSUP`). Load/unload state is serialized.
A plain file URL without a usable security grant is intentionally insufficient.

`FSSupportsPathURLs` and `FSRequiresSecurityScopedPathURLResources` are true,
matching Apple's downloaded `PassthroughAppEx/Info.plist`. Generic URL scheme
metadata and validation are preserved. The installed 26.5 `FSResource.h` declares
path-resource support and intact transport of security-scoped URLs. See Apple's
[FSPathURLResource documentation](https://developer.apple.com/documentation/fskit/fspathurlresource),
[passthrough example](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system),
and [balanced scope lifecycle](https://developer.apple.com/documentation/foundation/url/stopaccessingsecurityscopedresource()).

**Path-backed mount syntax and security-grant delivery on macOS 26 remain
unverified.** No path mount command is presented as working. The generic command
above remains an unverified candidate too. No extension was installed or activated
and no mount/unmount was attempted during M0A.

## M0A verification

Run `bash verify.sh` for the unsigned bundle build, SDK 26.5 compile/link checks
and all twelve tests. To run just the five new tests:

```sh
swift test --build-system native --scratch-path /private/tmp/mdb-m0a-tests \
  -Xswiftc -sdk -Xswiftc /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --filter PathResourceTests
```

The seven original tests cover tree contents, reads, enumeration, URL validation,
lookup/attributes and read-only mutations. Five new tests cover path syntax,
probe scope balancing, both load routes, duplicate/mismatched unloads, failure
cleanup, deinitialization and real metadata rejection. Security-scope calls are
injected for lifecycle tests: these prove accounting, not an OS-issued grant.
`FSTaskOptions` has no public initializer in SDK 26.5, so load/unload tests call
the same internal operations used directly by the FSKit callbacks.

Verification completed on 2026-10-24: five focused tests and all twelve tests
passed with zero failures; `verify.sh` passed its unsigned Xcode build and complete
host/extension SDK 26.5 compile/link checks. Logs: `/private/tmp/m0a-verification`.
`git diff --check`, a separate baseline comparison for these untracked files, and
plist validation passed. The initial sandboxed Swift invocation failed on compiler
cache access; the authorized retry passed without source/API/signing errors.

CodeRabbit completed in VS Code (review `e6e3e5fa-a970-4101-87d6-0e9e51e8b84d`)
with only the four M0A files selected: this README, `HelloFileSystem.swift`,
`Extension-Info.plist`, and `PathResourceTests.swift`. It reported no actionable
issues and four additional “LGTM!” comments, all inspected. The generated review
title referred to unrelated configuration changes, but the saved file-review map
and all four comments identify the correct M0A files. No fixes were requested.
Because the M0 project was already untracked, the review saw complete selected
files rather than a Git-tracked M0-to-M0A patch. This verification paragraph was
added after review; executable code and tests have not changed since verification.

The FSKit project remains untracked and nothing has been staged or committed.
A local checkpoint must deliberately include the existing M0 project baseline;
exclude unrelated MTP, build and other worktree changes.
The next milestone is resolving eligible signing, then separately authorized
activation and Finder mount verification; M1 integration has not begun.
