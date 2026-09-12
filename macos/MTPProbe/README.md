# AndroidMacBridge MTP Probe

This is a minimal macOS command-line tool that demonstrates direct MTP communication with an Android device over USB using `IOUSBHost` (Apple's modern DriverKit/User-space USB framework). 

It is designed to be as simple as possible, proving the viability of using `IOUSBHost` without `macFUSE` or kernel extensions.

## Features

1. Detects connected Android MTP devices.
2. Identifies and terminates conflicting Google daemons (e.g., "Android File Transfer Agent") that aggressively claim the USB interface.
3. Claims the MTP USB Interface using `IOUSBHostInterface`.
4. Locates the Bulk-IN and Bulk-OUT endpoints.
5. Initiates an MTP Session (`OpenSession`).
6. Retrieves device info (Manufacturer, Model, Serial Number).
7. Enumerates storage volumes (Internal Storage, SD Card) and their capacities.
8. Reads and parses the root directory contents of the storage volumes.

## Architecture

The project is structured into three parts:
- **MTPProbeLib**: Pure-Swift structures for parsing and serialising MTP packet containers (`MTPCommandContainer`, `MTPResponseContainer`, `MTPDataContainer`) and parsing payloads (Device Info, Storage Info, Object Info). This layer is entirely decoupled from USB hardware.
- **USBDeviceDiscovery**: Uses `IOKit` to scan the IO Registry for an interface matching Class 6 (Image), Subclass 1, Protocol 1 (PTP/MTP).
- **MTPDevice**: Wraps `IOUSBHostInterface` and `IOUSBHostPipe`, handling the low-level bulk transfers (`__sendIORequest`) required to transmit MTP containers back and forth.

## Build and Run

You must have Xcode and Swift installed on your macOS system.

```bash
cd macos/MTPProbe
swift build
.build/debug/MTPProbe
```

## Expected Output

When a device (e.g., a Samsung phone) is connected and unlocked in "File Transfer" (MTP) mode:

```text
AndroidMacBridge MTP Probe
==========================

Searching for MTP USB devices...

MTP interface detected
Service: 7439
VID: 0x04E8
PID: 0x6860

Terminating conflicting daemons...
Checking for conflicting daemons...

Establishing MTP session...
Successfully created IOUSBHostInterface and located bulk pipes.
MTP Session Opened Successfully!

Retrieving basic device information...
Manufacturer: samsung
Model: SM-S721B
Serial Number: AD19DFC48CF0ABB0EC0A9765AAFD812B
Device Version: S721BXXSEDZH9

Enumerating storage volumes...

* Internal storage
  ID: 0x10001
  Capacity: 224.3 GB
  Free Space: 99.7 GB
  Access: Read/Write

  Root Directory:
    * [DIR] Pictures
    * [DIR] VoiceChange
    * [DIR] log
    * [DIR] ERS
    * [DIR] Bus tkts
    * [DIR] Anime
    * [DIR] MIUI
    * [DIR] SHAREit
    * [DIR] UKM Spring 2025 -  Information Package
    * [DIR] Movies
    ... and 28 more items

MTP Probe complete.
```
