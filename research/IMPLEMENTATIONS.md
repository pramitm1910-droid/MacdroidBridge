# AndroidMacBridge — Existing Implementations Research

> **Scope**: Open-source and closed-source projects relevant to Android MTP on macOS.  
> **Purpose**: Extract architectural lessons, assess license compatibility for reuse.  
> **Date**: September 2026  
> **Important**: No code is copied from any of these projects. This document is for research only.

---

## Table of Contents

1. [OpenMTP](#1-openmtp)
2. [simple-mtpfs](#2-simple-mtpfs)
3. [Android File Transfer for Mac (Google)](#3-android-file-transfer-for-mac-google)
4. [MacDroid (proprietary, formerly FreeDroid-adjacent)](#4-macdroid-proprietary)
5. [Moorage](#5-moorage)
6. [DroidMount](#6-droidmount)
7. [SwiftMTP](#7-swiftmtp)
8. [libmtp](#8-libmtp)
9. [libusb](#9-libusb)
10. [License Compatibility Summary](#10-license-compatibility-summary)
11. [Key Architectural Lessons](#11-key-architectural-lessons)

---

## 1. OpenMTP

**Repository**: https://github.com/ganeshrvel/openmtp  
**License**: MIT License  
**Status**: Actively maintained (as of 2026)  
**Code Reuse**: ✅ MIT — freely reusable in proprietary projects with attribution  

### Overview

OpenMTP is the most sophisticated open-source Android file transfer application for macOS. It is an Electron/React app with a native C++ MTP backend. It does **not** create a Finder-visible volume; it provides its own dual-pane file manager UI (left: Mac, right: Android).

### Technology Stack

| Layer | Technology |
|---|---|
| Frontend | React (TypeScript) |
| App shell | Electron |
| Main process | Node.js |
| MTP core | C++ ("Kalam") + Node.js N-API bindings |
| USB access | libusb (via Kalam, NOT libmtp) |

### Architecture — Kalam MTP Backend

The key architectural decision in OpenMTP is the **rejection of libmtp** in favor of a custom C++ MTP implementation called **Kalam** that interfaces directly with `libusb`.

**Why this matters**: libmtp on macOS is known to be unreliable — it uses aggressive caching, has poor handling of the macOS `PTPCamera` driver conflict, and has stale-state issues with Android's MediaStore-backed MTP responder. By building directly on libusb, OpenMTP gets:
- Direct control over USB bulk transfers.
- Ability to handle Android-specific MTP quirks.
- Avoidance of libmtp's LGPL license complications.

### Key Implementation Details

- **Device Detection**: Polls for USB devices on a timer interval. When a device with VID/PID matching an Android device is found, it attempts to claim the USB interface.
- **Android File Transfer Agent Conflict**: OpenMTP explicitly checks for and kills the `Android File Transfer Agent` background process before attempting to claim the USB interface. This is critical — without this step, the Agent holds the interface and blocks all other MTP access.
- **File Operations**: Implemented in Kalam as direct MTP command sequences over libusb bulk endpoints.
- **Large File Handling**: Kalam handles >4GB transfers by using the 64-bit `ObjectSize` MTP property.

### Known Limitations (from issues/README)

- Conflicts with Google's Android File Transfer Agent (mitigated by killing the agent).
- Does not expose Android files through Finder — users must use OpenMTP's own UI.
- Some Samsung devices have quirks with MTP directory enumeration speed.
- Transfer speed can be lower than native Windows MTP due to Electron overhead.

### What We Can Learn

1. **Bypass libmtp for macOS**: Writing a custom MTP implementation on top of libusb is the correct approach for macOS stability.
2. **Kill Google's daemon first**: This is a mandatory pre-step.
3. **Direct libusb > libmtp** on macOS due to driver conflict handling.
4. **N-API pattern**: If building in Electron/Node.js, N-API is the correct native binding approach. (Not relevant for our Swift-native approach, but instructive architecturally.)

---

## 2. simple-mtpfs

**Repository**: https://github.com/phatina/simple-mtpfs  
**License**: **GPL-2.0**  
**Status**: Sporadic maintenance  
**Code Reuse**: ❌ GPL-2.0 — code **cannot** be incorporated into a proprietary closed-source product. Can only be studied as a reference.

### Overview

`simple-mtpfs` is a FUSE-based filesystem for mounting MTP devices. On macOS, it uses macFUSE (osxfuse) as the kernel bridge. It is a thin adapter that translates FUSE filesystem callbacks into libmtp operations.

### Architecture

```
Kernel VFS
    ↓  (macFUSE kext)
FUSE callbacks (readdir, read, write, unlink, mkdir, etc.)
    ↓
simple-mtpfs.cpp (adapter layer)
    ↓
libmtp API
    ↓
libusb
    ↓
USB hardware (Android phone)
```

### Key Source File: `src/simple-mtpfs.cpp`

This is the heart of the project. It implements the standard FUSE operation callbacks and maps them to MTP API calls:

| FUSE callback | MTP operation |
|---|---|
| `readdir` | `GetObjectHandles` → `GetObjectInfo` for each handle |
| `getattr` | `GetObjectInfo` (caches result) |
| `read` | `GetObject` (streams to file descriptor) |
| `write` | `SendObjectInfo` + `SendObject` |
| `unlink` | `DeleteObject` |
| `mkdir` | `SendObjectInfo` with Association format code |
| `rename` | `SetObjectPropValue(ObjectFileName)` |
| `rmdir` | `DeleteObject` |

### Known Limitations

- **macOS only works with macFUSE** (kext required — problematic on Apple Silicon).
- **Caching**: Inherits libmtp's in-memory cache. Files added to the device by Android apps don't appear until the filesystem is remounted.
- **Rename semantics**: MTP rename is not atomic. Moving files between directories requires copy + delete (libmtp implements `MoveObject` where supported, but falls back).
- **Crash on disconnect**: If the USB cable is disconnected while a FUSE operation is in flight, the process can hang or crash, requiring manual unmount (`umount` or `diskutil unmount`).

### What We Can Learn

1. **The FUSE callback → MTP mapping is the core algorithm** we must implement in our FSKit extension. The mapping in `simple-mtpfs.cpp` is the best available reference for this adaptation.
2. **Caching is problematic**: We should design our MTP layer to minimize caching and detect stale state proactively.
3. **Disconnect handling is critical**: We must implement graceful disconnect at the filesystem extension level (FSKit's equivalent of FUSE's unmount callback).
4. **GPL license means**: We cannot use this code. We can study the algorithm and re-implement it independently.

---

## 3. Android File Transfer for Mac (Google)

**Repository**: Not open-source (proprietary).  
**License**: Proprietary / Closed-source  
**Code Reuse**: ❌ Not available — closed source, proprietary.

### Overview

Google's official macOS MTP client, released circa 2012. Effectively **abandonware** as of 2026 — no meaningful updates in many years.

### Architecture

Built as a native Cocoa app using `IOKit` directly (predating libusb's maturity on macOS). It includes a background `LaunchAgent` called **"Android File Transfer Agent"** (`/Library/Application Support/Google/AndroidFileTransfer/Android File Transfer Agent.app`).

### Why It's a Problem

The Android File Transfer Agent:
- Runs as a persistent background process.
- Monitors for USB device connections.
- Claims the MTP USB interface the moment an Android device is connected.
- **Blocks all other MTP software from accessing the device**.
- Does not expose a public API for other apps to use.
- Cannot easily be disabled by users (it re-launches itself).

### Known Limitations

- **4GB file transfer limit** (hardcoded) — uses 32-bit size in `SendObjectInfo`.
- Crashes frequently during batch transfers of many small files.
- No support for Android 10+ Scoped Storage quirks.
- Shows its own window (popup UI) rather than Finder integration.
- The Agent process persists even after closing the main app.

### What We Can Learn

1. **We must kill the Android File Transfer Agent** before claiming the USB device. This is a known mandatory step.
2. **Using IOKit directly** (as Google did) is the correct approach for macOS — more reliable than libusb for interface claiming.
3. **The 4GB limit is a client-side choice** — it can be overcome by using the 64-bit MTP size property.
4. **A background LaunchAgent model is viable** for persistent device monitoring — Google's approach proves this works, even if their implementation is stale.

---

## 4. MacDroid (Proprietary)

**Repository**: No public repository (closed-source commercial product by Electronic Team, Inc.)  
**License**: Proprietary (commercial)  
**Code Reuse**: ❌ Not available.

> **Note on "FreeDroid"**: There is no notable open-source macOS Android file transfer project specifically named "FreeDroid" — FreeDroid is an unrelated open-source RPG game. The closest match to the originally referenced product concept is **MacDroid**, a well-known commercial macOS Android file manager, or alternatively small hobby projects that may not have maintained public repositories.

### Overview

MacDroid is the premier commercial macOS app for exposing Android storage in Finder. It uses **macFUSE** to mount the Android device as a native volume visible in Finder's sidebar under "Locations."

### Architecture (Inferred from behavior and public documentation)

- Uses macFUSE for the Finder-visible volume mount.
- Likely uses libmtp or a custom MTP implementation for device communication.
- Requires macFUSE to be installed separately.

### Relevance

MacDroid proves that **the macFUSE + MTP combination works for Finder integration**. However:
- It requires macFUSE installation (kext friction on Apple Silicon).
- It is commercial — no source code available.
- Its approach is the legacy path. Our project uses FSKit/File Provider as the modern alternative.

### What We Can Learn

1. **The market gap**: A native macOS (no FUSE kext) Android Finder integration is not yet properly served by open-source tools.
2. **FSKit is our opportunity**: MacDroid's reliance on macFUSE is a weakness we can exploit by building a kext-free FSKit-based alternative.

---

## 5. Moorage

**Repository**: Likely a small/personal project; no prominent public repository found.  
**License**: Unknown (likely GPL due to FUSE/libmtp linkage if it existed)  
**Status**: Effectively inactive/not found as a distinct project.

### Research Findings

"Moorage" does not appear as a distinct, well-established macOS Android MTP project in public repositories. It may refer to:
- A very small personal project.
- An internal name for an unreleased project.
- A conflation with another tool.

The concept matches **DroidMount** (see below) — a menu-bar wrapper around macFUSE + libmtp for automatic Android mounting.

### What We Can Learn

The absence of a mature "Moorage" confirms there is a **gap in the market** for a well-engineered, open-source, FUSE-free Android filesystem integration for macOS.

---

## 6. DroidMount

**Repository**: Older projects exist (various small GitHub repos); none are dominant or well-maintained.  
**License**: GPL (due to macFUSE/libmtp linkage)  
**Status**: Abandoned or inactive.

### Overview

DroidMount was a menu-bar utility concept that automatically mounts Android devices as volumes using macFUSE + libmtp when plugged in. It provided:
- A system tray icon showing connection status.
- Automatic mount/unmount on USB connect/disconnect.
- Volume appears in Finder (via macFUSE).

### Architecture

```
IOKit USB notification
    ↓
DroidMount daemon (detects Android device)
    ↓
macFUSE mount (FUSE filesystem in user space)
    ↓
libmtp (MTP protocol)
    ↓
libusb (USB transport)
    ↓
Android device
```

### What We Can Learn

1. **The menu-bar daemon model is correct**: Automatic mount/unmount without user intervention is the right UX paradigm. Our daemon should follow this pattern.
2. **GPL license problem**: Because it links to macFUSE (GPL-2.0) and libmtp (LGPL-2.1), any FUSE-based approach has license complications for proprietary development. Our FSKit-based approach avoids this entirely.
3. **IOKit notifications for hot-plug** are the correct mechanism for automatic detection — confirmed by DroidMount's approach.

---

## 7. SwiftMTP

**Repository**: No prominent, mature, maintained public repository.  
**License**: Typically MIT for experimental projects.  
**Status**: Experimental / proof-of-concept level.

### Overview

"SwiftMTP" refers to experimental Swift implementations of MTP client code on macOS, typically using Apple's `IOUSBHost` framework instead of libusb. These are mostly proof-of-concepts demonstrating that:

1. It is possible to speak MTP directly from Swift without C/C++ libraries.
2. `IOUSBHost` (Apple's native USB framework in Swift) is sufficient for basic MTP operations.
3. The Microsoft OS String Descriptor can be read from Swift to identify MTP devices.

### What We Can Learn

1. **IOUSBHost is Swift-accessible**: Our daemon can be written entirely in Swift, calling `IOUSBHost` natively without bridging to C libraries. This is the most "Apple-native" approach.
2. **The MTP protocol is implementable from scratch in Swift**: For a proprietary product wanting to avoid libmtp's LGPL complications, a Swift MTP implementation is viable.
3. **These are immature references**: Do not use SwiftMTP code directly — treat it only as proof that the approach works.

---

## 8. libmtp

**Repository**: https://github.com/libmtp/libmtp  
**License**: **LGPL-2.1**  
**Code Reuse**: ⚠️ Conditional — can be dynamically linked in proprietary apps (with attribution and providing the LGPL library separately). Cannot be statically linked into a closed-source proprietary binary without complex compliance measures.

### Overview

libmtp is the canonical cross-platform C library for MTP device communication. It is built on libusb and provides a high-level object-oriented API above raw MTP commands.

### Key Technical Details

- **Device database**: `src/device-flags.h` — a massive hardcoded list of VID/PID combinations with quirk flags. This is invaluable reference data for understanding which devices need special treatment.
- **Core data structures**: `LIBMTP_file_t`, `LIBMTP_folder_t`, `LIBMTP_mtpdevice_t`.
- **Session management**: `LIBMTP_Open_Raw_Device_Uncached()` opens a device; `LIBMTP_Release_Device()` closes it.
- **File enumeration**: `LIBMTP_Get_Filelisting_With_Callback()` returns linked list of file objects (slow for large libraries — fetches all objects).
- **Download**: `LIBMTP_Get_File_To_File_Descriptor()` — streams to a file descriptor.
- **Upload**: `LIBMTP_Send_File_From_File_Descriptor()` — streams from a file descriptor.
- **Error handling**: C-style error codes + `LIBMTP_Dump_Errorstack()`.

### macOS-Specific Problems

1. **PTPCamera driver conflict**: libmtp's `libusb_detach_kernel_driver()` often fails silently on macOS, leaving the interface claimed by the kernel.
2. **Image Capture conflict**: macOS's Image Capture framework also competes for the device.
3. **Caching issues**: libmtp maintains an in-memory object tree. If Android modifies files externally, the cache is stale until session restart.

### LGPL Compliance for Proprietary Products

Under LGPL-2.1:
- ✅ **Dynamic linking** is permitted in closed-source proprietary software, provided you: (a) give attribution, (b) provide the LGPL library separately (allow users to replace it), and (c) include the LGPL text.
- ❌ **Static linking** into a closed-source binary is generally not permitted without additional compliance measures (releasing the object files so users can relink with a modified library).
- ✅ **Studying the source** for algorithm reference is always permitted.

**Recommendation**: Avoid libmtp entirely. Write a custom MTP layer on top of `IOUSBHost`. This eliminates the LGPL dependency and gives full control over macOS-specific driver conflict handling.

---

## 9. libusb

**Repository**: https://github.com/libusb/libusb  
**License**: **LGPL-2.1**  
**Code Reuse**: ⚠️ Same LGPL conditions as libmtp.

### Overview

libusb provides a portable, user-space USB access API. Its macOS backend uses `IOKit` / `IOUSBHost`.

### Apple Silicon Compatibility

libusb builds as a Universal Binary (arm64 + x86_64) and runs natively on Apple Silicon. No known ARM64-specific issues. Must be compiled with appropriate architecture flags.

### macOS-Specific Issues

- **Kernel driver detachment**: `libusb_detach_kernel_driver()` is unreliable on macOS. The macOS `IOKit` backend's implementation of this function may silently fail if the `PTPCamera` or `IOUSBHost` driver has claimed the interface.
- **Alternative**: Use `IOUSBHost` directly (native Swift/ObjC API), which provides more reliable interface ownership transfer. `IOUSBHostInterface::open()` can supersede the default kernel driver.

### What We Can Learn

The lesson from libusb's macOS limitations is that **using Apple's native `IOUSBHost` framework is superior to libusb** for our macOS-specific application. libusb adds cross-platform portability that we don't need (we are macOS-only).

---

## 10. License Compatibility Summary

| Project | License | Reuse in Proprietary Product | Reference Only |
|---|---|---|---|
| **OpenMTP (Kalam core)** | MIT | ✅ Yes, with attribution | ✅ Yes |
| **simple-mtpfs** | GPL-2.0 | ❌ No | ✅ Yes |
| **Android File Transfer (Google)** | Proprietary (closed source) | ❌ No | ❌ No (source unavailable) |
| **MacDroid** | Proprietary (commercial) | ❌ No | ❌ No (source unavailable) |
| **DroidMount** (if GPL) | GPL | ❌ No | ✅ Yes |
| **libmtp** | LGPL-2.1 | ⚠️ Dynamic linking only | ✅ Yes |
| **libusb** | LGPL-2.1 | ⚠️ Dynamic linking only | ✅ Yes |
| **SwiftMTP (experimental)** | MIT (typical) | ✅ Yes (if verified) | ✅ Yes |

### Recommended Approach

For a proprietary product:
1. **OpenMTP's MIT architecture** is the best reference model. Study it deeply.
2. **simple-mtpfs's FUSE callback → MTP mapping** is the best algorithm reference. Re-implement independently.
3. **Avoid libmtp and libusb** as direct dependencies. Write a native Swift `IOUSBHost`-based MTP stack.
4. The `device-flags.h` from libmtp is LGPL, but its **data** (VID/PID lists) can be referenced and independently compiled into our own device database since raw device IDs are factual data, not protectable expression.

---

## 11. Key Architectural Lessons

### Lesson 1: The Google Agent Must Be Killed First
Every successful third-party MTP implementation on macOS must explicitly terminate the Google Android File Transfer Agent (`Android File Transfer Agent.app`) before attempting to claim the USB interface. This is not optional.

### Lesson 2: libusb < IOUSBHost on macOS
libusb's macOS backend wraps `IOKit`, but its kernel driver detachment is unreliable. Apple's native `IOUSBHost` framework gives more direct, reliable interface ownership. New code should use `IOUSBHost`.

### Lesson 3: libmtp's Cache is a Liability
libmtp maintains an in-memory object tree that gets stale when Android changes files externally. A better design either (a) never caches (always queries the device), or (b) implements fine-grained invalidation via MTP event notifications.

### Lesson 4: A Custom MTP Layer is Worth It
OpenMTP's decision to write Kalam (a custom C++ MTP implementation) instead of using libmtp was correct. For our Swift-native project, a Swift MTP implementation on `IOUSBHost` is the analogous choice.

### Lesson 5: FUSE/macFUSE is the Wrong Foundation for New Projects
All the FUSE-based projects (simple-mtpfs, DroidMount, MacDroid) prove the Finder integration concept but are blocked on Apple Silicon by kext requirements. FSKit is the correct modern replacement.

### Lesson 6: The FUSE Callback → MTP Mapping is Well-Understood
`simple-mtpfs.cpp` provides the definitive mapping from POSIX filesystem operations to MTP commands. This is the core algorithm we need to implement in our FSKit extension. We must reimplement it independently (not copy it) due to GPL.

### Lesson 7: Object Handle Instability is Real
MTP object handles are implementation-defined and can change between sessions (disconnect/reconnect). File Provider requires stable item identifiers. We must maintain a `stablePath → stableID` mapping database that survives reconnection cycles.

### Lesson 8: Enumeration Speed is a UX Problem
`GetObjectHandles` + per-object `GetObjectInfo` is slow for large directories. OpenMTP and similar tools use async enumeration (show partial results while loading). Our filesystem extension must handle this gracefully — perhaps showing folders first, then populating files asynchronously.

### Lesson 9: There Is No Production-Quality Open-Source Native macOS Finder Integration
The market gap is real: there is no open-source, kext-free, Finder-native Android filesystem integration for macOS. This is our opportunity.
