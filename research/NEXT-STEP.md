# AndroidMacBridge — Next Step

> **Status**: Research complete. No code implemented.  
> **This file contains ONLY the smallest practical first milestone.**  
> Do not implement anything described here until explicitly directed.

---

## The Smallest Practical Next Milestone

### Milestone 0: MTP Device Probe (Command-Line Tool)

Build a **standalone command-line tool** (not yet a full app, not yet a Finder extension) that:

1. Detects when an Android phone in MTP mode is connected via USB.
2. Claims the USB interface (after terminating the Google Android File Transfer Agent if running).
3. Opens an MTP session.
4. Prints the device name, storage volumes, and the top-level directory listing.
5. Closes the MTP session cleanly.
6. Detects when the USB cable is disconnected and exits gracefully.

### Why This Specific Milestone

- It validates the single most uncertain technical point: **can we reliably claim the USB interface from macOS and speak MTP to an Android device using `IOUSBHost` in Swift, without libmtp?**
- It is entirely self-contained — no App Extensions, no System Extensions, no entitlements required beyond a basic macOS command-line tool.
- It de-risks the entire project before investing in the more complex FSKit or File Provider layers.
- It is the minimum viable proof that the MTP layer works.
- It is completable in 1–3 days of focused work.

### Scope (Strictly Limited)

**Included**:
- IOKit USB hot-plug detection (IOServiceAddMatchingNotification).
- Google Android File Transfer Agent termination.
- IOUSBHost interface claim.
- MTP `OpenSession`, `GetDeviceInfo`, `GetStorageIDs`, `GetStorageInfo`, `GetObjectHandles` (root level only), `GetObjectInfo`, `CloseSession`.
- Graceful disconnect handling.
- Console output only.

**Explicitly Excluded**:
- File download or upload.
- Recursive directory traversal.
- Any UI.
- Any App Extension.
- Any FSKit or File Provider code.
- Any daemon/service infrastructure.
- libmtp or libusb (use IOUSBHost directly).

### Success Criteria

Running the tool with an Android phone connected (set to MTP mode) produces output like:

```
Device detected: Samsung Galaxy S24 (VID=0x04E8, PID=...)
Killed Android File Transfer Agent: yes
USB interface claimed: yes
MTP session opened: yes

Storage volumes:
  [0x00010001] Internal Storage — 256.0 GB total, 128.3 GB free
  [0x00020001] SD Card — 128.0 GB total, 64.1 GB free

Root of Internal Storage:
  [DIR ] DCIM/
  [DIR ] Download/
  [DIR ] Documents/
  [DIR ] Android/
  [FILE] .nomedia (0 bytes)

USB disconnected. Session closed cleanly.
```

### Failure Modes to Validate Against

- Phone in Charging-only mode (expected: device not detected as MTP — print guidance).
- Google Android File Transfer app not installed (expected: graceful, no crash).
- Another MTP client already has the interface (expected: error message, not crash).
- USB disconnected mid-enumeration (expected: graceful exit, no hang).

---

## After This Milestone Is Complete

Only after the MTP probe tool works reliably should the next milestone be scoped. The likely next step would be adding file download (reading a file from Android to Mac) to validate large-file MTP transfer, before touching any filesystem extension code.

Do not scope beyond this milestone now.
