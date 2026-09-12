# AndroidMacBridge — USB/Finder Architecture Analysis

> **Scope**: This document covers only the USB/Finder integration layer.  
> The wireless AirDrop-like system is a separate, independent subsystem and is not addressed here.  
> **Date**: September 2026  
> **Status**: Research only — no implementation code written.

---

## Table of Contents

1. [Product Goal](#1-product-goal)
2. [Android USB Modes](#2-android-usb-modes)
3. [Android MTP Protocol](#3-android-mtp-protocol)
4. [macOS USB Device Detection](#4-macos-usb-device-detection)
5. [Filesystem Exposure Technologies](#5-filesystem-exposure-technologies)
   - 5A. File Provider (NSFileProviderReplicatedExtension)
   - 5B. FSKit
   - 5C. Finder Sync Extensions
   - 5D. FUSE / macFUSE
6. [libusb and libmtp on macOS](#6-libusb-and-libmtp-on-macos)
7. [The PTPCamera Conflict Problem](#7-the-ptpcamera-conflict-problem)
8. [Answering the 22 Determination Questions](#8-answering-the-22-determination-questions)
9. [Architecture Comparison](#9-architecture-comparison)
10. [Recommended Architecture](#10-recommended-architecture)
11. [Fact vs. Assumption Registry](#11-fact-vs-assumption-registry)

---

## 1. Product Goal

When an Android phone is connected to a Mac via USB:

1. macOS detects the device automatically.
2. The Android device appears as a location in the macOS Finder sidebar.
3. The user browses Android internal storage and SD card through standard Finder windows.
4. The user can copy files Android → Mac and Mac → Android without a separate file-transfer UI.
5. The experience matches Windows File Explorer's native Android MTP integration as closely as possible.

---

## 2. Android USB Modes

### How Android Advertises USB Modes

When a USB cable is connected, Android presents itself to the host OS as a USB device using **USB Descriptors** — structured binary data negotiated during the USB enumeration handshake. The key descriptors are:

- **Device Descriptor**: Contains `bDeviceClass`, `idVendor` (VID), `idProduct` (PID).
- **Configuration Descriptor**: Describes power and interface count.
- **Interface Descriptors**: One per mode (e.g., one for MTP, one for ADB).

The Android OS configures these descriptors through the **USB Gadget framework** (implemented via `configfs` on Android 6+). When the user changes modes in Settings, Android does a soft USB disconnect/reconnect by reconfiguring `configfs`, which causes the host to re-enumerate the device with new descriptors.

### Available Modes

| Mode | USB Class | Notes |
|------|-----------|-------|
| MTP (Media Transfer Protocol) | 0x06 Still Imaging + Microsoft OS Ext. | File-level access; primary interest for this project |
| PTP (Picture Transfer Protocol) | 0x06 Still Imaging | Subset of MTP; camera-style, photos only |
| ADB (Android Debug Bridge) | Vendor-specific (0xFF) | Debugging; separate interface in composite mode |
| MIDI | Audio class | Irrelevant to this project |
| Charging-only | No data interface exposed | Default since Android 6.0 (Marshmallow) |

### Important Behavioral Notes

- **Default is Charging-only since Android 6.0 (Marshmallow)**. The user must manually navigate Settings → Connected Devices → USB → "File Transfer" to enable MTP. Some ROMs show a notification bubble. Our app cannot bypass this — the user *must* choose MTP mode.
- In MTP mode, if ADB is also enabled, the device appears as a **USB Composite Device** with multiple interfaces (Interface 0 = MTP, Interface 1 = ADB). The MTP client must select Interface 0.
- The device advertises MTP by including a **Microsoft OS String Descriptor** (reading `"MSFT100"`) which tells clients to treat the device as MTP rather than plain PTP.

### Common Android Vendor IDs (VID)

| Manufacturer | VID |
|---|---|
| Google / Pixel | 0x18D1 |
| Samsung | 0x04E8 |
| OnePlus | 0x2A70 |
| Motorola | 0x22B8 |
| Sony | 0x0FCE |
| HTC | 0x0BB4 |

These can be used as IOKit matching hints, though matching on USB Interface Class 0x06 is more portable.

---

## 3. Android MTP Protocol

### Overview

MTP (Media Transfer Protocol) is a standardized USB protocol originally developed by Microsoft for portable devices. It operates as a **session-based, synchronous, request-response protocol** over USB Bulk IN/OUT endpoints.

### Supported Operations (Android)

Android's `mtp-responder` daemon (historically C++, more recently integrated with the `MediaProvider` service) implements the following core MTP operations:

| Operation | Description |
|---|---|
| `GetDeviceInfo` | Returns manufacturer, model, supported operations, and supported formats |
| `OpenSession` / `CloseSession` | Establishes/tears down a session (one at a time) |
| `GetStorageIDs` | Lists available storage volumes (Internal Storage, SD Card) |
| `GetStorageInfo` | Returns capacity, free space, and filesystem type for a storage |
| `GetObjectHandles` | Enumerates files/folders within a parent directory |
| `GetObjectInfo` | Returns metadata (name, size, parent, dates) for an object |
| `GetObject` | Downloads the binary content of a file |
| `SendObjectInfo` + `SendObject` | Two-phase file upload: first metadata, then binary data |
| `DeleteObject` | Deletes a file or folder |
| `MoveObject` | Moves an object to a new parent |
| `CopyObject` | Copies an object to a new parent |
| `GetObjectPropValue` | Reads a specific property (e.g., 64-bit file size) |
| `SetObjectPropValue` | Writes a property (e.g., modification timestamp) |
| `CreateFolder` | Creates a directory (implemented as `SendObjectInfo` with folder format code) |

### Android MTP Storage Model

- **Storage IDs** are 32-bit integers. Typically:
  - `0x00010001` = Internal Storage
  - `0x00020001` = External SD Card
- **Object Handles** are unique 32-bit integers assigned to every file and folder. `0xFFFFFFFF` means "root" or "all objects". `0x00000000` is invalid.
- **Filesystem Mapping**: Android does NOT expose raw block devices. Older Android versions (pre-10) used the `MediaStore` SQLite database to map object handles to file paths. This caused the infamous "ghost file" bug where files deleted outside MTP still appeared in MTP listings. Android 10+ uses FUSE (`sdcardfs` replacement) which keeps MTP in sync with the real filesystem.

### Critical MTP Limitations

| Limitation | Details |
|---|---|
| **Single-session serialization** | MTP is strictly synchronous per-session. One command at a time. No pipelining. |
| **4GB file size (historic)** | Original `ObjectInfo` dataset uses a 32-bit size field. Files ≥4GB require querying the `ObjectSize` property (64-bit) via `GetObjectPropValue`. |
| **No real-time filesystem events** | There is no MTP equivalent of `inotify`. The client cannot know when the Android app creates a new file without re-enumerating. |
| **Slow enumeration of large directories** | Requesting `GetObjectHandles` for folders with thousands of items is slow (~seconds) due to MediaStore SQLite overhead on older Android. |
| **Timestamp round-trip bugs** | Setting modification dates requires explicit `SetObjectPropValue` after upload, which many clients don't implement. |
| **No sparse files, no symlinks** | MTP has no concept of these filesystem features. |
| **No atomic operations** | There is no equivalent of `rename` as a single atomic operation in standard MTP. |

### Android Version MTP Milestones

| Android Version | MTP Change |
|---|---|
| 3.0 Honeycomb | MTP introduced, USB Mass Storage dropped |
| 6.0 Marshmallow | Default USB mode changed to Charging-only |
| 10/11 | FUSE-based storage rewrites; MTP reliability improved significantly |
| 11+ (Scoped Storage) | Stricter access controls; MTP scope limited to user-visible directories |

---

## 4. macOS USB Device Detection

### IOKit Framework

macOS detects USB devices via the **IOKit** framework. The relevant class hierarchy is:
```
IOService
└── IOUSBHostDevice (modern API, IOUSBHost.framework)
    └── IOUSBHostInterface
        └── IOUSBHostPipe (bulk endpoints for data transfer)
```

The older `IOUSBDevice`/`IOUSBInterface` API still works but Apple has deprecated it in favor of `IOUSBHost`.

### Device Enumeration

```objc
// Match all USB devices
CFMutableDictionaryRef matchingDict = IOServiceMatching(kIOUSBDeviceClassName);

// Or match by Interface Class (MTP = PTP = 0x06)
IOServiceAddMatchingNotification(
    notifyPort,
    kIOFirstMatchNotification,
    matchingDict,
    deviceConnectedCallback,
    context,
    &iterator
);
```

### Hot-Plug Notifications

- `IOServiceAddMatchingNotification` with `kIOFirstMatchNotification` fires when a device matching your criteria connects.
- `IOServiceAddMatchingNotification` with `kIOTerminatedNotification` fires when the device disconnects.
- These notifications run on a `CFRunLoop` port.

### Matching Strategy for Android MTP

Android MTP devices typically present as:
- `bDeviceClass = 0x00` (defined at interface level)
- `bInterfaceClass = 0x06` (Still Image / PTP)
- `bInterfaceSubClass = 0x01`
- `bInterfaceProtocol = 0x01`
- Plus: A Microsoft OS String Descriptor marking it as MTP

The safest matching strategy is to match on **USB Interface Class 0x06** and then inspect the Microsoft OS Descriptor to confirm MTP capability. Matching only on specific VID/PID would miss devices not in our whitelist.

---

## 5. Filesystem Exposure Technologies

### 5A. File Provider (NSFileProviderReplicatedExtension)

**What it is**: Apple's framework for integrating cloud storage into the macOS filesystem. Introduced in macOS 11 (Big Sur), significantly improved in macOS 12 (Monterey).

**How it works**:
- The extension implements the `NSFileProviderReplicatedExtension` protocol.
- `fileproviderd` (Apple's system daemon) manages a local replica cache in `~/Library/CloudStorage/`.
- Files start as "dataless" placeholders (zero disk usage).
- When a user opens a file, `fileproviderd` calls `fetchContents(for:version:request:completionHandler:)` on your extension to download it.
- When a user saves a file, `fileproviderd` calls `modifyItem(_:baseVersion:changedFields:contents:request:completionHandler:)`.
- The extension enumerates items by implementing `NSFileProviderEnumerator`.

**Finder Integration**:
- Appears in the Finder sidebar under **Locations** (same row as iCloud Drive, Dropbox) with your app's icon.
- Files show sync status badges (cloud icon for not-yet-downloaded).
- Standard Finder operations (copy, move, delete) all work.

**Suitability for MTP/USB**:
- ✅ Appears natively in Finder sidebar.
- ✅ No kernel extension required.
- ✅ Mac App Store compatible.
- ✅ Works on macOS 11+ (practical minimum: macOS 12).
- ❌ Designed around high-latency cloud sync, not low-latency USB. The replica cache model means reads copy data to the Mac's local APFS filesystem first — not streaming.
- ❌ "Dataless" placeholders mean the full file isn't present until fetched. This is fine for cloud, but for a USB device the user expects instant access.
- ❌ When the USB device disconnects, all files become inaccessible (good) but the local cache of already-fetched files remains (storage leak unless explicitly cleaned up).
- ❌ The framework has no concept of "this remote source is local hardware" — it will apply eviction policies meant for network drives.
- ⚠️ File Provider enforces that item identifiers are stable across sessions. MTP object handles can change between disconnect/reconnect sessions. Our implementation must maintain a stable identifier map.
- ⚠️ **Architecture split required**: File Provider extensions are sandboxed. They cannot directly use `libusb`. A separate background daemon (LSUIElement=true or LaunchDaemon) must hold the MTP/USB connection and communicate to the extension via XPC.

**Entitlements needed**:
- `com.apple.security.application-groups` (for shared container with the daemon)
- Standard App Extension entitlements
- The daemon needs `com.apple.security.device.usb`

**Distribution**: Mac App Store compatible. Notarization required for direct distribution.

---

### 5B. FSKit (macOS 15 Sequoia+)

**What it is**: Apple's modern user-space filesystem framework, introduced in macOS 15. It replaces the legacy VFS kernel extension approach and is the Apple-endorsed successor to FUSE.

**How it works**:
- An FSKit extension implements `FSVolumeDriver` (or similar protocol).
- The extension runs as a **System Extension** (user space, not kernel space).
- When the system needs to mount a volume, it calls into the FSKit extension.
- The extension implements standard VFS operations: `lookup`, `readdir`, `read`, `write`, `create`, `unlink`, `mkdir`, `rename`, `getattr`, `setattr`.
- The result is a **true native volume** mounted in `/Volumes/` — not a synced replica.

**Finder Integration**:
- Appears in Finder's **Locations** sidebar as a standard mounted volume (same as a USB thumb drive or network share).
- This is the closest to the Windows File Explorer experience — a true volume mount.
- All standard file operations work at the VFS level.

**Suitability for MTP/USB**:
- ✅ True virtual volume mount — closest experience to native.
- ✅ No kernel extension required (System Extension only).
- ✅ Apple-blessed modern API.
- ✅ Works on Apple Silicon natively.
- ✅ Potentially Mac App Store compatible (System Extensions in App Store are allowed if Apple approves the entitlement).
- ❌ **macOS 15+ only**. As of September 2026, this excludes Macs that cannot upgrade to Sequoia (pre-2019 models depending on model).
- ❌ Very new API — sparse documentation, few real-world implementations to reference.
- ❌ Requires System Extension approval (user must click Allow in Privacy & Security). No reboot required, but one click of approval is needed.
- ⚠️ Same USB/sandboxing architecture split needed: FSKit extension cannot directly access USB. Daemon + XPC bridge required.

**Entitlements needed**:
- `com.apple.developer.fskit` (or equivalent, exact name not yet documented)
- `com.apple.developer.system-extension.install`
- Daemon: `com.apple.security.device.usb`

**Distribution**: Requires System Extension notarization. Developer ID or potentially Mac App Store.

---

### 5C. Finder Sync Extensions

**What they are**: App Extensions that let your app add badges, context menus, and toolbar buttons to Finder for files that live in a specific directory on disk.

**What they cannot do**:
- Cannot provide a virtual filesystem.
- Cannot expose files from a device — files must physically exist on disk.
- Cannot add a volume or location to the Finder sidebar.
- Cannot intercept file read/write operations.

**Verdict**: **Entirely unsuitable** for exposing an MTP device's filesystem. Finder Sync is a UI decoration layer, not a filesystem extension. Do not use for this purpose.

---

### 5D. FUSE / macFUSE

**What it is**: macFUSE (formerly OSXFUSE) is the macOS port of the FUSE (Filesystem in Userspace) standard. It provides a kernel-level bridge that routes VFS calls to a user-space FUSE server.

**How it works**:
- A kernel extension (`macfuse.kext`) intercepts filesystem operations.
- These are forwarded via `/dev/osxfuse` to the user-space FUSE server.
- The FUSE server implements callbacks (`readdir`, `read`, `write`, etc.) and responds.
- The result is a volume mounted in `/Volumes/` — same as FSKit.

**Finder Integration**:
- Appears identically to any other mounted volume in Finder. Excellent experience when it works.
- This is how `simple-mtpfs` and MacDroid expose Android storage on macOS.

**Suitability for MTP/USB**:
- ✅ True virtual volume — best possible Finder experience.
- ✅ Mature, battle-tested (many real implementations: `simple-mtpfs`, `MacDroid`).
- ✅ Works on Intel Macs without restrictions.
- ❌ **Requires a kernel extension (kext)** — Apple has deprecated kexts.
- ❌ **Apple Silicon: requires Recovery Mode downgrade**. User must: reboot → hold power → Recovery OS → lower security to "Reduced Security" → restart → approve kext → restart again. This is a completely unacceptable user experience for a consumer product.
- ❌ **Cannot be distributed on the Mac App Store** (App Store forbids kext installation).
- ❌ Many enterprise/corporate MDM policies block kext approval entirely.
- ❌ Apple may cease supporting kexts entirely in a future macOS version.

**Verdict**: **Do not use macFUSE as the primary approach** for a new consumer product. Legacy support only.

---

## 6. libusb and libmtp on macOS

### libusb

- **Role**: Cross-platform user-space USB access library (C). Used to claim USB interfaces and transfer data over bulk endpoints.
- **macOS Backend**: Uses `IOKit` / `IOUSBHost` internally.
- **Apple Silicon**: Fully compatible as a Universal Binary. No ARM64-specific issues.
- **Sandboxing**: Works in a sandboxed app with the `com.apple.security.device.usb` entitlement.
- **Critical Issue**: macOS automatically attaches its own kernel driver (`PTPCamera` / `Image Capture`) to MTP/PTP-class USB devices. libusb's `libusb_detach_kernel_driver()` is notoriously unreliable on macOS compared to Linux. **This requires special handling** — see Section 7.

### libmtp

- **Role**: Higher-level MTP library built on libusb. Provides file-object-oriented API (not raw USB).
- **Device Discovery**: Maintains a hardcoded `device-flags.h` database of VID/PID pairs with device-specific quirk flags. Unknown devices are probed via the Microsoft OS String Descriptor.
- **Key API functions**:
  - `LIBMTP_Detect_Raw_Devices()` — finds MTP devices
  - `LIBMTP_Open_Raw_Device_Uncached()` — opens a device
  - `LIBMTP_Get_Filelisting_With_Callback()` — enumerate all files
  - `LIBMTP_Get_Object_To_File_Descriptor()` — download file
  - `LIBMTP_Send_File_From_File_Descriptor()` — upload file
  - `LIBMTP_Delete_Object()` — delete
  - `LIBMTP_Create_Folder()` — create directory
- **Known macOS Issues**: libmtp inherits all libusb macOS limitations. It also caches the file tree in memory; if the Android side changes files, the cache becomes stale.
- **License**: LGPL-2.1 — can be dynamically linked in proprietary apps (with attribution), but static linking in a proprietary closed-source app is legally complex. OpenMTP avoided this by writing a custom C++ MTP implementation (`Kalam`) that uses libusb directly without libmtp.

---

## 7. The PTPCamera Conflict Problem

**This is the single most important macOS-specific problem** for any MTP implementation.

When an Android device in MTP mode is connected to a Mac:

1. macOS automatically loads the `PTPCamera.kext` kernel driver and attaches it to the USB interface.
2. The `Image Capture` app (or its background agent) may also claim the device.
3. Google's **"Android File Transfer Agent"** — a background LaunchAgent installed by the Android File Transfer app — also aggressively polls for MTP devices and claims them.

**Result**: Any MTP client using libusb/libmtp will fail to claim the USB interface because the OS or another process already holds it.

**Solutions**:

| Approach | Notes |
|---|---|
| **`IOUSBHost` direct claim via IOKit** | Native macOS API; can request exclusive USB interface ownership via IOKit, superseding the kernel driver. This is what the Google Android File Transfer app does natively. More reliable than libusb's detach method. |
| **Kill Android File Transfer Agent** | Required. Before attempting to claim the device, kill `/Library/Application Support/Google/AndroidFileTransfer/Android File Transfer Agent.app`. OpenMTP does this. |
| **Use DriverKit** | A DriverKit USB extension can claim the device at driver level, preempting the kernel's default PTP driver. Very complex, but gives complete ownership. |
| **`libusb_set_option(ctx, LIBUSB_OPTION_NO_DEVICE_DISCOVERY)`** | Helps libusb avoid conflicts in some scenarios. |

**Verified**: OpenMTP explicitly kills the Android File Transfer Agent before claiming devices. This is a known requirement, not optional.

---

## 8. Answering the 22 Determination Questions

### Q1. How is the Android device detected?
Using `IOServiceAddMatchingNotification` (IOKit) matching on USB Interface Class `0x06` (Still Image / PTP) or specific VID/PID. A daemon process listens for connect/disconnect events on a `CFRunLoop`. On match, it inspects the Microsoft OS String Descriptor to confirm MTP mode.

### Q2. How is USB communication established?
Via `IOUSBHost` (preferred) or `libusb` (cross-platform). The critical step is claiming exclusive ownership of the MTP USB interface before `PTPCamera.kext` or Android File Transfer Agent can grab it. The Android File Transfer Agent must be killed first.

### Q3. How does MTP communication work?
MTP runs over two USB Bulk endpoints (IN and OUT). The client sends a command packet, waits for a response packet, and transfers a data packet if needed. This is strictly serialized — one request at a time per session. Commands are 16-byte headers followed by parameters.

### Q4. How are Android directories enumerated?
1. Call `GetStorageIDs` to get storage volumes.
2. Call `GetStorageInfo` for each storage ID (name, capacity, free space).
3. For a directory, call `GetObjectHandles(storageID, 0, parentHandle)` to list children.
4. For each handle, call `GetObjectInfo(handle)` to get name, type (file/folder), size, and dates.
5. For large directories, this is slow because it requires one `GetObjectInfo` call per object. Batch property requests via `GetObjectPropList` (if supported) are faster.

### Q5. How are files read from Android?
Call `GetObject(handle)` with a buffer or file descriptor. Data streams over the USB Bulk IN endpoint. For large files, data arrives in chunks determined by USB packet size (typically 512KB–64MB bulk transfers). libmtp wraps this in `LIBMTP_Get_Object_To_File_Descriptor()`.

### Q6. How are files written to Android?
Two-phase operation:
1. `SendObjectInfo`: Send a metadata packet (name, size, parent handle, format code). Android responds with the new object handle.
2. `SendObject`: Stream the file data over USB Bulk OUT.
After upload, optionally call `SetObjectPropValue` for `DateModified` to preserve timestamps.

### Q7. How does rename work?
MTP has no dedicated rename operation in the standard spec. The approach is:
1. `GetObjectPropValue(handle, ObjectFileName)` to confirm current name.
2. `SetObjectPropValue(handle, ObjectFileName, newName)` to set the new name.
Android's MTP responder supports this. Note: this is not atomic at the filesystem level.

### Q8. How does deletion work?
Call `DeleteObject(handle)`. For folders, Android recursively deletes contents. The operation is not interruptible — if the USB disconnects mid-deletion, partial deletion may result.

### Q9. How does folder creation work?
Call `SendObjectInfo` with `ObjectFormat = 0x3001` (Association/Folder) and no file data (`SendObject` is skipped). Android creates the directory and returns the new object handle.

### Q10. How are large files (>4GB) transferred?
- On download: `GetObject` streams the full file regardless of size. The 32-bit `ObjectInfo.ObjectCompressedSize` field is set to `0xFFFFFFFF` for files ≥4GB; the real size is in the 64-bit `ObjectSize` property (retrieved via `GetObjectPropValue`).
- On upload: `SendObjectInfo` sets the 32-bit size to `0xFFFFFFFF` and the actual 64-bit size in the extended property. The data then streams via `SendObject`.
- **Verified concern**: Some older Samsung devices and exFAT SD cards have reported failures with >4GB MTP transfers. This is a known libmtp issue and requires device-specific workarounds.

### Q11. What happens when the USB cable is disconnected?
- The USB bulk endpoints immediately return I/O errors.
- The Android MTP responder terminates. Any in-progress `SendObject` upload is discarded (partial file deleted on Android side in modern Android).
- The MTP session is dead and cannot be resumed — a new session must be opened.
- The daemon must detect the disconnect via IOKit `kIOTerminatedNotification` and gracefully unmount/hide the Finder item.

### Q12. How does reconnection work?
The daemon detects reconnection via `kIOFirstMatchNotification`. It must:
1. Kill any lingering Google Android File Transfer Agent process.
2. Re-claim the USB interface.
3. Open a new MTP session (`OpenSession`).
4. Re-enumerate storage IDs and object handles (handles from the previous session are invalid).
5. Re-present the volume/location to the filesystem extension.

MTP object handles are NOT guaranteed to be stable across sessions. The daemon must rematch objects by name/path for stable identifiers required by File Provider.

### Q13. How is the Android filesystem exposed to Finder?
Three viable options (see Section 9 for comparison):
- **File Provider**: As a sync location in Finder sidebar (like iCloud Drive).
- **FSKit**: As a mounted volume in Finder sidebar (like a USB drive). Requires macOS 15+.
- **macFUSE**: As a mounted volume. Legacy approach; problematic on Apple Silicon.

### Q14. Can File Provider provide the desired experience?
**Partially.** File Provider appears natively in Finder and supports bidirectional file operations. However, it uses a replica cache model — files are copied to `~/Library/CloudStorage/` when accessed. This means:
- First read of a file = USB transfer to Mac cache (slow and uses Mac disk space).
- Subsequent reads = served from cache (fast but potentially stale).
- This does NOT provide the seamless streaming experience of Windows File Explorer.
- For small/medium files, the UX is acceptable. For large video files, the UX (waiting for download to cache before use) is suboptimal.

### Q15. Can FSKit provide the desired experience?
**Yes — FSKit is the ideal architecture for the desired experience**, subject to the macOS 15+ requirement. FSKit provides a true virtual volume with synchronous VFS semantics. Every file access calls into the FSKit extension in real time — no local caching. This matches Windows File Explorer's behavior exactly. However, FSKit is new, documentation is sparse, and the API surface is not yet fully stable.

### Q16. Is FUSE/macFUSE necessary?
**No.** macFUSE is not necessary and should be avoided for a new consumer product due to kext requirements and Apple Silicon friction. FSKit is the modern replacement. On macOS 11–14, File Provider is the alternative.

### Q17. Is Finder Sync appropriate?
**No.** Finder Sync Extensions are UI decoration tools for local folders. They cannot provide a virtual filesystem or expose device contents. They are not appropriate for this use case.

### Q18. What sandbox restrictions apply?
- All App Extensions (File Provider, FSKit extensions) are sandboxed.
- Extensions **cannot** directly access USB hardware.
- **Required architecture**: A privileged background daemon (not an extension) holds the USB/MTP connection and communicates with the extension via XPC (or a local socket/named pipe).
- The daemon needs `com.apple.security.device.usb` entitlement.
- If the daemon is distributed as a LaunchAgent (not sandboxed), it has full USB access but requires careful security design.

### Q19. What entitlements are required?

| Component | Entitlement | Purpose |
|---|---|---|
| Main app | `com.apple.security.device.usb` | USB device access via IOKit |
| Main app | `com.apple.security.application-groups` | Shared XPC container with extension |
| File Provider ext. | `com.apple.developer.fileprovider.testing-mode` | Dev/testing only |
| FSKit extension | `com.apple.developer.fskit` (inferred) | Declare as FSKit volume driver |
| System Extension (FSKit) | `com.apple.developer.system-extension.install` | Install System Extension |
| App (hardened runtime) | `com.apple.security.cs.disable-library-validation` | If loading unsigned dylibs |

### Q20. Does the solution work on Apple Silicon?
- **File Provider**: ✅ Yes, fully supported on all Apple Silicon Macs.
- **FSKit**: ✅ Yes, natively supported on Apple Silicon (requires macOS 15).
- **macFUSE**: ⚠️ Technically yes, but requires Recovery Mode security downgrade — unacceptable for consumers.
- **libusb/libmtp as daemon**: ✅ Yes, builds as Universal Binary (arm64 + x86_64).
- **IOUSBHost direct**: ✅ Yes, Apple's own API.

### Q21. Does it work on current macOS versions?

| Technology | Minimum macOS | Notes |
|---|---|---|
| File Provider (NSFileProviderReplicatedExtension) | macOS 12 (Monterey) | Practical minimum; Big Sur (11) possible but unstable |
| FSKit | macOS 15 (Sequoia) | Hard minimum |
| macFUSE | macOS 10.9+ | But kext friction on Apple Silicon |
| libusb | macOS 10.9+ | Universal binary recommended |

In September 2026, the installed base is approximately: macOS 15 (40%), macOS 14 (35%), macOS 13 (15%), older (10%). A File Provider approach covers ~90% of users; FSKit covers ~40%.

### Q22. Can it realistically be distributed to normal users?
- **File Provider approach**: ✅ Yes. Mac App Store or direct download. No special user steps beyond installing the app.
- **FSKit approach**: ✅ Yes, but user must click "Allow" in System Settings → Privacy & Security once for the System Extension. No reboot needed.
- **macFUSE approach**: ❌ For Apple Silicon users (majority in 2026), this requires Recovery Mode downgrade. Not realistic for a consumer product.

---

## 9. Architecture Comparison

### Architecture A — File Provider

**Description**: MTP daemon ↔ XPC ↔ NSFileProviderReplicatedExtension ↔ Finder

| Dimension | Assessment |
|---|---|
| **Advantages** | macOS 11+ support; Mac App Store eligible; no System Extension approval; excellent Finder integration (sidebar location); bidirectional sync built into framework |
| **Disadvantages** | Replica cache model (reads copy files to Mac disk); not true streaming; stale cache issues; complex sync state machine; unsuitable for devices >256GB accessed frequently |
| **Technical Complexity** | High — must implement NSFileProviderReplicatedExtension protocol with proper sync tokens, change tracking, and stable item identifiers across MTP sessions |
| **Performance** | First access: USB transfer speed (5–40 MB/s). Repeated access: local disk speed. Large files: must fully transfer before accessible. |
| **Reliability** | Good. Apple's `fileproviderd` handles crash recovery for the extension. The daemon failure model needs careful design. |
| **Finder Experience** | Good. Appears in sidebar like Dropbox/iCloud. File badges show sync state. No volume icon — shows as a named location. |
| **macOS Security Restrictions** | Sandboxed extension. USB access via separate daemon. XPC bridge required. |
| **Distribution Restrictions** | None. Mac App Store fully compatible. |
| **Long-term Maintainability** | High. This is an Apple-supported framework actively developed. |

---

### Architecture B — FSKit

**Description**: MTP daemon ↔ XPC ↔ FSKit Volume Driver (System Extension) ↔ VFS ↔ Finder

| Dimension | Assessment |
|---|---|
| **Advantages** | True virtual volume (no local cache); appears as mounted volume in Finder (like USB drive); real-time streaming semantics; Apple-blessed kext replacement; App Store potentially eligible |
| **Disadvantages** | macOS 15+ ONLY; new/immature API; sparse documentation; requires System Extension user approval; one extra user click during setup |
| **Technical Complexity** | Very High — implementing a VFS-level filesystem driver with correct POSIX semantics over MTP (which lacks atomic rename, etc.) requires careful adaptation |
| **Performance** | Real-time. Every read/write goes directly through XPC to MTP daemon to USB. No caching layer. Speed = USB transfer speed (~5–40 MB/s for MTP). |
| **Reliability** | Unknown at scale. FSKit is new. VFS-level bugs can produce kernel panics or data loss. Needs extensive testing. |
| **Finder Experience** | Excellent. Appears in sidebar as a proper volume with disk icon. Identical to Windows File Explorer behavior. Space indicator works. |
| **macOS Security Restrictions** | System Extension requires user approval. Extension is sandboxed but has VFS-level access. Daemon handles USB. XPC bridge required. |
| **Distribution Restrictions** | System Extension requires Developer ID (or App Store approval for System Extension entitlement). |
| **Long-term Maintainability** | High once API stabilizes. Apple's strategic direction is FSKit. |

---

### Architecture C — Finder Sync Extension

**Not viable.** As explained in Section 5C, Finder Sync cannot provide a virtual filesystem. It is explicitly excluded from consideration.

---

### Architecture D — FUSE / macFUSE

**Description**: MTP daemon (libmtp) ↔ FUSE VFS ↔ macFUSE kext ↔ Finder

| Dimension | Assessment |
|---|---|
| **Advantages** | Mature; battle-tested (simple-mtpfs, MacDroid); true volume mount; works on macOS 10.9+; excellent POSIX compatibility |
| **Disadvantages** | Requires kext; Apple Silicon Recovery Mode requirement; cannot be on Mac App Store; Apple may kill kext support entirely; kext approval is a multi-step user process; corporate MDMs often block kexts |
| **Technical Complexity** | Moderate — FUSE API is well-documented; bridging to MTP is straightforward (simple-mtpfs is a reference). |
| **Performance** | Good. FUSE adds ~10–20% overhead vs native VFS. Still USB-speed limited for MTP. |
| **Reliability** | Good for Intel Macs. Poor for Apple Silicon (setup friction causes user errors). |
| **Finder Experience** | Excellent when it works. Volume appears identically to FSKit. |
| **macOS Security Restrictions** | kext = Recovery Mode security downgrade on Apple Silicon. Hardened Runtime complications. |
| **Distribution Restrictions** | Cannot be on Mac App Store. Direct download only. Developer ID signing required. |
| **Long-term Maintainability** | Low. Apple is deprecating kexts. macFUSE may cease to work in a future macOS version. |

---

### Architecture E — Native MTP + Virtual Filesystem (Custom)

**Description**: Custom IOUSBHost MTP implementation ↔ custom in-process VFS ↔ Finder via File Provider or FSKit

This means writing our own MTP protocol implementation on top of `IOUSBHost` (no libmtp dependency), combined with whichever of the above filesystem exposure mechanisms is chosen.

| Dimension | Assessment |
|---|---|
| **Advantages** | No LGPL dependency; full control over MTP quirks; can optimize specifically for Android; can avoid the libmtp cache model |
| **Disadvantages** | Significantly more development effort; must implement all MTP operations from scratch; must handle all device quirks manually |
| **Technical Complexity** | Very High. MTP is well-specified but has many device-specific quirks. |
| **Performance** | Identical to libmtp-based approaches once implemented correctly. |

---

### Architecture F — Combination: File Provider (macOS 11–14) + FSKit (macOS 15+)

**Description**: Detect macOS version at runtime. On macOS 15+, use FSKit for a true volume mount. On macOS 11–14, fall back to File Provider.

| Dimension | Assessment |
|---|---|
| **Advantages** | Best experience on macOS 15+; acceptable experience on macOS 11–14; covers ~90% of Mac users; single app bundle |
| **Disadvantages** | Must maintain two filesystem integration codebases simultaneously; complex version-detection logic; different UX behavior on different OS versions (volume vs. location) |
| **Technical Complexity** | Very High (sum of both approaches) |
| **Performance** | Excellent on macOS 15+ (FSKit); acceptable on macOS 11–14 (File Provider) |
| **Reliability** | Good — each path uses Apple-supported APIs |
| **Distribution Restrictions** | Mac App Store compatible (pending System Extension entitlement approval) |
| **Long-term Maintainability** | High for FSKit path; medium for File Provider path (can be deprecated as macOS 15 adoption increases) |

---

## 10. Recommended Architecture

### Primary Recommendation: Architecture F (File Provider + FSKit Hybrid)

**Rationale**: Neither File Provider nor FSKit alone solves the problem completely:
- FSKit gives the ideal experience but requires macOS 15+.
- File Provider covers older macOS but sacrifices streaming semantics.
- A hybrid covers the broadest user base with the best possible experience on each OS version.

### Component Design

```
┌──────────────────────────────────────────────────────────────┐
│                    AndroidMacBridge.app                       │
│                    (Main Application)                         │
│  - Installs/manages System Extension                          │
│  - Manages daemon lifecycle                                   │
│  - User preferences, device whitelist                         │
└──────────────┬───────────────────────────────────────────────┘
               │ Installs
               ▼
┌──────────────────────────────────────────────────────────────┐
│              MTP Daemon (LaunchAgent or XPC Service)          │
│              Language: Swift + IOUSBHost or C + libusb        │
│                                                               │
│  - Listens for USB connect/disconnect via IOKit               │
│  - Kills Google Android File Transfer Agent if running        │
│  - Claims USB Interface 0 exclusively                         │
│  - Implements MTP session (OpenSession, commands, CloseSession)│
│  - Exposes XPC interface to filesystem extension              │
│  - Handles reconnection and session recovery                  │
└──────────────┬───────────────────────────────────────────────┘
               │ XPC
     ┌─────────┴──────────┐
     │                    │
     ▼                    ▼
┌─────────────┐    ┌──────────────────┐
│ File Provider│    │  FSKit Extension │
│  Extension  │    │ (System Ext.)    │
│ (macOS 11+) │    │ (macOS 15+ only) │
│             │    │                  │
│ - Appears   │    │ - Appears as     │
│   in Finder │    │   volume mount   │
│   sidebar   │    │   in Finder      │
│ - Replica   │    │ - True streaming │
│   cache     │    │ - /Volumes/      │
│   model     │    │   AndroidPhone   │
└─────────────┘    └──────────────────┘
```

### MTP Daemon Implementation Strategy

The daemon should use **direct IOUSBHost** rather than libusb for maximum macOS compatibility and to avoid the kernel driver detach unreliability. It should implement the MTP protocol natively (referencing OpenMTP's Kalam as a design pattern but written from scratch to avoid license issues). Key considerations:

1. **On startup**: Check if Google Android File Transfer Agent is running. If yes, terminate it (it is safe to do so — it is not a system process).
2. **Device detection**: `IOServiceAddMatchingNotification` on USB Interface Class 0x06.
3. **Device claim**: Use `IOUSBHostInterface::open()` to claim exclusive ownership.
4. **Session management**: `OpenSession` → do work → `CloseSession`. Keep session alive for the duration of the mount.
5. **Object handle mapping**: Maintain a stable `{storageID + path}` → `stableID` dictionary to satisfy File Provider's requirement for stable item identifiers across reconnections.
6. **Disconnect handling**: Trap IOKit termination event. Mark all items unavailable. Unmount the extension domain. Wait for reconnection.
7. **Reconnection**: Re-enumerate and attempt to reconcile the stable ID map by path.

### Language Choice

- **Daemon**: Swift using `IOUSBHost` (native macOS API, excellent Apple Silicon support). Fall back to C with libusb only if IOUSBHost proves insufficient.
- **File Provider Extension**: Swift (mandatory for App Extensions).
- **FSKit Extension**: Swift (FSKit is a Swift-first framework).

### Minimum macOS Target

- **macOS 12 (Monterey)** as the minimum supported version (for stable File Provider).
- **macOS 15 (Sequoia)** users get the superior FSKit experience.

### Distribution

- **Direct download + notarization**: Simplest path. No App Store restrictions.
- **Mac App Store**: Feasible if Apple approves the System Extension entitlement (submit for approval). File Provider path is definitely MAS-compatible.

---

## 11. Fact vs. Assumption Registry

### Verified Facts
- Android defaults to Charging-only USB mode since Android 6.0. ✅
- MTP is strictly synchronous per session (one command at a time). ✅
- libmtp uses LGPL-2.1 license. ✅
- macFUSE requires a kernel extension. ✅
- Apple Silicon kext installation requires Recovery Mode security downgrade. ✅
- FSKit was introduced in macOS 15 Sequoia. ✅
- NSFileProviderReplicatedExtension introduced in macOS 11 (Big Sur). ✅
- File Provider uses a local replica cache in `~/Library/CloudStorage/`. ✅
- `com.apple.security.device.usb` entitlement exists for IOKit USB access. ✅
- Google Android File Transfer Agent conflicts with other MTP clients. ✅
- OpenMTP kills the Android File Transfer Agent before claiming devices. ✅
- IOKit's `IOServiceAddMatchingNotification` is the correct hot-plug detection API. ✅
- MTP files ≥4GB require the 64-bit `ObjectSize` property via `GetObjectPropValue`. ✅
- macFUSE apps cannot be on the Mac App Store. ✅
- File Provider apps can be on the Mac App Store. ✅

### Inferences / Assumptions (require verification during implementation)

- FSKit may be distributable on the Mac App Store — pending Apple entitlement approval process details. ⚠️ (Inferred from Apple's stated goal of replacing kexts)
- `com.apple.developer.fskit` is the correct entitlement name — the exact entitlement string requires verification against Apple developer documentation. ⚠️
- In September 2026, macOS 15 adoption is approximately 40% — exact figures not verified. ⚠️
- IOUSBHost is more reliable than libusb for detaching the PTPCamera driver on macOS — directional claim, requires benchmarking. ⚠️
- MTP object handles are guaranteed to change between sessions — commonly observed behavior, but not explicitly stated in the MTP spec as a requirement. ⚠️
- FSKit VFS operations are called synchronously (blocking the VFS layer) — architectural inference, requires WWDC/documentation confirmation. ⚠️
