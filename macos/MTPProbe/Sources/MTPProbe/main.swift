import Foundation
import CryptoKit
import IOKit
import MTPProbeLib

struct MTPProbeCLI {
    static let usage = """
AndroidMacBridge MTP Probe
==========================

Usage:
  MTPProbe                     Run the default discovery / inventory probe
  MTPProbe probe              Same as default behavior
  MTPProbe upload <file> [--storage-id N] [--format 0x3000] [--name filename.txt]
  MTPProbe download <file> [--name filename.txt] [--output /tmp/downloaded.bin]
  MTPProbe --help             Show this message

Examples:
  swift run MTPProbe upload /tmp/test.txt
  swift run MTPProbe upload /tmp/test.txt --storage-id 0x00010001 --name hello.txt
"""

    static func parse(_ arguments: [String]) -> (mode: String, fileURL: URL?, storageID: UInt32, format: UInt16, name: String?, outputURL: URL?) {
        let args = Array(arguments.dropFirst())

        if args.isEmpty || args[0] == "probe" {
            return ("probe", nil, 0, 0x3000, nil, nil)
        }

        if args[0] == "--help" || args[0] == "-h" || args[0] == "help" {
            return ("help", nil, 0, 0x3000, nil, nil)
        }

        if args[0] == "upload" {
            var filePath: String?
            var storageID: UInt32 = 0
            var format: UInt16 = 0x3000
            var name: String?

            var index = 1
            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--storage-id":
                    if index + 1 < args.count {
                        storageID = parseUInt32(args[index + 1])
                        index += 2
                    } else {
                        index += 1
                    }
                case "--format":
                    if index + 1 < args.count {
                        format = UInt16(parseUInt32(args[index + 1]))
                        index += 2
                    } else {
                        index += 1
                    }
                case "--name":
                    if index + 1 < args.count {
                        name = args[index + 1]
                        index += 2
                    } else {
                        index += 1
                    }
                default:
                    if filePath == nil {
                        filePath = arg
                    }
                    index += 1
                }
            }

            return ("upload", filePath.map { URL(fileURLWithPath: $0) }, storageID, format, name, nil)
        }

        if args[0] == "download" {
            var filePath: String?
            var name: String?
            var outputPath: String?
            var index = 1
            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--name":
                    if index + 1 < args.count {
                        name = args[index + 1]
                        index += 2
                    } else {
                        index += 1
                    }
                case "--output":
                    if index + 1 < args.count {
                        outputPath = args[index + 1]
                        index += 2
                    } else {
                        index += 1
                    }
                default:
                    if filePath == nil {
                        filePath = arg
                    }
                    index += 1
                }
            }
            return (
                "download",
                filePath.map { URL(fileURLWithPath: $0) },
                0,
                0x3000,
                name,
                outputPath.map { URL(fileURLWithPath: $0) }
            )
        }

        let filePath: String? = args.first
        if filePath != nil && !args.first!.hasPrefix("-") {
            var storageID: UInt32 = 0
            var format: UInt16 = 0x3000
            var name: String?
            var index = 1
            while index < args.count {
                let arg = args[index]
                switch arg {
                case "--storage-id":
                    if index + 1 < args.count { storageID = parseUInt32(args[index + 1]); index += 2 } else { index += 1 }
                case "--format":
                    if index + 1 < args.count { format = UInt16(parseUInt32(args[index + 1])); index += 2 } else { index += 1 }
                case "--name":
                    if index + 1 < args.count { name = args[index + 1]; index += 2 } else { index += 1 }
                default:
                    index += 1
                }
            }
            return ("upload", URL(fileURLWithPath: filePath!), storageID, format, name, nil)
        }

        return ("probe", nil, 0, 0x3000, nil, nil)
    }

    static func parseUInt32(_ value: String) -> UInt32 {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("0x") {
            let hex = String(cleaned.dropFirst(2))
            return UInt32(hex, radix: 16) ?? UInt32(cleaned) ?? 0
        }
        return UInt32(cleaned) ?? 0
    }
}

func runDiscoveryProbe() {
    print("AndroidMacBridge MTP Probe")
    print("==========================\n")
    print("Searching for MTP USB devices...")

    do {
        let service = try USBDeviceDiscovery.findFirstMTPInterface()

        print("\nMTP interface detected")
        print("Service: \(service)")

        var props: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)

        if result == kIOReturnSuccess, let propertiesDict = props?.takeRetainedValue() as? [String: Any] {
            if let vendorID = propertiesDict["idVendor"] as? Int {
                print(String(format: "VID: 0x%04X", vendorID))
            }
            if let productID = propertiesDict["idProduct"] as? Int {
                print(String(format: "PID: 0x%04X", productID))
            }
        }

        print("\nTerminating conflicting daemons...")
        AndroidDaemonKiller.terminateConflictingDaemons()
        Thread.sleep(forTimeInterval: 1.0)

        print("\nEstablishing MTP session...")
        let device = try MTPDevice(service: service)
        try device.openSession()

        print("\nRetrieving basic device information...")
        let deviceInfo = try device.getDeviceInfo()
        print("Manufacturer: \(deviceInfo.manufacturer)")
        print("Model: \(deviceInfo.model)")
        print("Serial Number: \(deviceInfo.serialNumber)")
        print("Device Version: \(deviceInfo.deviceVersion)")

        print("\nEnumerating storage volumes...")
        let storageIDs = try device.getStorageIDs()
        if storageIDs.isEmpty {
            print("No storage volumes found.")
        }

        for id in storageIDs {
            let storageInfo = try device.getStorageInfo(storageID: id)
            print("\n* \(storageInfo.displayName)")
            print("  ID: 0x\(String(id, radix: 16, uppercase: true))")
            print("  Capacity: \(storageInfo.capacityString)")
            print("  Free Space: \(storageInfo.freeString)")
            print("  Access: \(storageInfo.accessCapability == 0 ? "Read/Write" : "Read Only")")

            print("\n  Root Directory:")
            let objectHandles = try device.getObjectHandles(storageID: id)
            if objectHandles.isEmpty {
                print("    (Empty)")
            } else {
                for handle in objectHandles.prefix(10) {
                    let objectInfo = try device.getObjectInfo(objectHandle: handle)
                    let type = objectInfo.isDirectory ? "[DIR]" : "[FILE]"
                    print("    * \(type) \(objectInfo.filename)")
                }
                if objectHandles.count > 10 {
                    print("    ... and \(objectHandles.count - 10) more items")
                }
            }
        }

        IOObjectRelease(service)
        print("\nMTP Probe complete.")
    } catch USBDiscoveryError.noDevicesFound {
        print("No MTP USB devices found. Please ensure an Android device is connected and unlocked in MTP (File Transfer) mode.")
    } catch {
        print("Error during USB discovery: \(error)")
    }
}

func runUploadTest(fileURL: URL, storageID: UInt32, format: UInt16, name: String?) {
    print("AndroidMacBridge MTP Probe")
    print("==========================\n")
    print("Preparing real MTP upload test...")
    print("Source: \(fileURL.path)")
    print("Storage ID: 0x\(String(storageID, radix: 16, uppercase: true))")
    print("Format: 0x\(String(format, radix: 16, uppercase: true))")

    do {
        let service = try USBDeviceDiscovery.findFirstMTPInterface()
        print("\nMTP interface detected")

        AndroidDaemonKiller.terminateConflictingDaemons()
        Thread.sleep(forTimeInterval: 1.0)

        let device = try MTPDevice(service: service)
        try device.openSession()

        let storageIDs = try device.getStorageIDs()
        guard !storageIDs.isEmpty else {
            print("No MTP storage volumes were found on the connected device.")
            IOObjectRelease(service)
            return
        }

        let storageInfoByID = try Dictionary(uniqueKeysWithValues: storageIDs.map { id in
            let info = try device.getStorageInfo(storageID: id)
            return (id, info)
        })

        let chosenStorageID = MTPStorageSelector.chooseStorageID(
            requestedStorageID: storageID,
            allStorageIDs: storageIDs,
            storageInfoByID: storageInfoByID
        )

        if storageID == 0 && chosenStorageID != 0 {
            print("Auto-selected writable storage: 0x\(String(chosenStorageID, radix: 16, uppercase: true))")
        } else if storageID != 0 {
            print("Selected storage: 0x\(String(chosenStorageID, radix: 16, uppercase: true))")
        }

        if chosenStorageID == 0 {
            print("No writable MTP storage was found on the connected device.")
            IOObjectRelease(service)
            return
        }

        if storageID != 0 && !storageIDs.contains(storageID) {
            print("Requested storage ID 0x\(String(storageID, radix: 16, uppercase: true)) was not found. Available IDs: \(storageIDs.map { "0x\(String($0, radix: 16, uppercase: true))" }.joined(separator: ", "))")
            IOObjectRelease(service)
            return
        }

        print("\nUploading to storage 0x\(String(chosenStorageID, radix: 16, uppercase: true))")
        let result = try device.uploadFile(
            at: fileURL,
            storageID: chosenStorageID,
            parentHandle: 0xFFFFFFFF,
            filename: name ?? fileURL.lastPathComponent,
            format: format
        )

        print("\nUpload success: \(result.filename)")
        print("Object handle: 0x\(String(result.objectHandle, radix: 16, uppercase: true))")
        print("Storage ID: 0x\(String(chosenStorageID, radix: 16, uppercase: true))")
        print("Size: \(result.objectCompressedSize) bytes")

        IOObjectRelease(service)
        print("\nMac → Samsung MTP transfer test complete.")
    } catch USBDiscoveryError.noDevicesFound {
        print("No MTP USB devices found. Please ensure the Samsung is connected and in File Transfer mode.")
    } catch {
        print("Upload failed: \(error)")
    }
}

func findObjectHandle(on device: MTPDevice, filename: String) throws -> UInt32? {
    let storageIDs = try device.getStorageIDs()
    for storageID in storageIDs {
        let handles = try device.getObjectHandles(storageID: storageID)
        for handle in handles {
            let info = try device.getObjectInfo(objectHandle: handle)
            if !info.isDirectory && info.filename == filename {
                return handle
            }
        }
    }
    return nil
}

func runDownloadVerify(originalURL: URL, name: String?, outputURL: URL?) {
    print("AndroidMacBridge MTP Probe")
    print("==========================\n")
    print("Preparing Samsung → Mac GetObject test...")
    print("Original Mac file: \(originalURL.path)")

    let targetName = name ?? originalURL.lastPathComponent
    let destination = outputURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("mtp-getobject-\(targetName)")

    do {
        let service = try USBDeviceDiscovery.findFirstMTPInterface()
        print("\nMTP interface detected")

        AndroidDaemonKiller.terminateConflictingDaemons()
        Thread.sleep(forTimeInterval: 1.0)

        let device = try MTPDevice(service: service)
        try device.openSession()

        guard let handle = try findObjectHandle(on: device, filename: targetName) else {
            print("Object named \(targetName) was not found on the device.")
            IOObjectRelease(service)
            return
        }

        print("Found object handle: 0x\(String(handle, radix: 16, uppercase: true))")
        print("GetObject (0x1009) ...")

        let payload = try device.getObject(handle: handle)
        try payload.write(to: destination)

        let originalData = try Data(contentsOf: originalURL)
        let originalHash = SHA256.hash(data: originalData).map { String(format: "%02x", $0) }.joined()
        let downloadedHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        print("\nDownloaded to: \(destination.path)")
        print("Original size: \(originalData.count) bytes")
        print("Downloaded size: \(payload.count) bytes")
        print("Original SHA-256: \(originalHash)")
        print("Downloaded SHA-256: \(downloadedHash)")

        if originalData.count == payload.count && originalHash == downloadedHash {
            print("Byte-for-byte verification: PASS")
        } else {
            print("Byte-for-byte verification: FAIL")
            exit(1)
        }

        IOObjectRelease(service)
        print("\nSamsung → Mac MTP GetObject test complete.")
    } catch USBDiscoveryError.noDevicesFound {
        print("No MTP USB devices found. Please ensure the Samsung is connected and in File Transfer mode.")
        exit(1)
    } catch let error as MTPDeviceError {
        print(error.description)
        exit(1)
    } catch {
        print("Download failed: \(error)")
        exit(1)
    }
}

let cli = MTPProbeCLI.parse(CommandLine.arguments)

switch cli.mode {
case "help":
    print(MTPProbeCLI.usage)
case "upload":
    guard let fileURL = cli.fileURL else {
        print(MTPProbeCLI.usage)
        exit(1)
    }
    if !FileManager.default.fileExists(atPath: fileURL.path) {
        print("File not found: \(fileURL.path)")
        exit(1)
    }
    runUploadTest(fileURL: fileURL, storageID: cli.storageID, format: cli.format, name: cli.name)
case "download":
    guard let fileURL = cli.fileURL else {
        print(MTPProbeCLI.usage)
        exit(1)
    }
    if !FileManager.default.fileExists(atPath: fileURL.path) {
        print("Original Mac file not found: \(fileURL.path)")
        exit(1)
    }
    runDownloadVerify(originalURL: fileURL, name: cli.name, outputURL: cli.outputURL)
default:
    runDiscoveryProbe()
}
