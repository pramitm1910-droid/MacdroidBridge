# AndroidMacBridge MTP Probe

This is a minimal macOS command-line tool that demonstrates direct MTP communication with an Android device over USB using `IOUSBHost` (Apple's modern DriverKit/User-space USB framework). 

It is designed to be as simple as possible, proving the viability of using `IOUSBHost` without `macFUSE` or kernel extensions.

## Features

1. Detects connected Android MTP devices.
2. Identifies and terminates conflicting Google daemons (e.g., "Android File Transfer Agent") that aggressively claim the USB interface.
3. Claims the MTP USB Interface using `IOUSBHostInterface`.
4. Locates the Bulk-IN and Bulk-OUT endpoints.
5. Initiates an MTP Session (`OpenSession`).
6. Retrieves device information (manufacturer, model and protocol metadata).
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
