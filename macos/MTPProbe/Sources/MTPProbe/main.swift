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
  MTPProbe probe-storage-refresh  Discover storage, then accept one explicit stdin refresh action
  MTPProbe probe-folder-browser --first-directory  Bounded root/child/back metadata verification
  MTPProbe probe-root-metadata  List at most 32 root objects; no content access
  MTPProbe probe-diagnostic   Enumerate storage without terminating apps or logging serial numbers
  MTPProbe probe-diagnostic --trace-storage-ids [--note "text"]...  Trace once with optional annotations
  MTPProbe probe-storage-info <storage-id>  Query one supplied ID only if enumeration is empty
  MTPProbe upload <file> [--storage-id N] [--format 0x3000] [--name filename.txt]
  MTPProbe download <file> [--name filename.txt] [--output /tmp/downloaded.bin]
  MTPProbe --help             Show this message

Examples:
  swift run MTPProbe upload /tmp/test.txt
  swift run MTPProbe upload /tmp/test.txt --storage-id 0x00010001 --name hello.txt
"""

    static func parse(_ arguments: [String]) -> (mode: String, fileURL: URL?, storageID: UInt32, format: UInt16, name: String?, outputURL: URL?, notes: [String]) {
        let args = Array(arguments.dropFirst())

        if args.first == "probe-storage-refresh" {
            guard args == ["probe-storage-refresh"] else { print("Usage: MTPProbe probe-storage-refresh"); exit(1) }
            return ("probe-storage-refresh", nil, 0, 0x3000, nil, nil, [])
        }
        if args.first == "probe-folder-browser" {
            guard args == ["probe-folder-browser", "--first-directory"] else {
                print("Usage: MTPProbe probe-folder-browser --first-directory"); exit(1)
            }
            return ("probe-folder-browser", nil, 0, 0x3000, nil, nil, [])
        }
        if args.first == "probe-root-metadata" {
            guard args.count == 1 else { print("Usage: MTPProbe probe-root-metadata"); exit(1) }
            return ("probe-root-metadata", nil, 0, 0x3000, nil, nil, [])
        }
        if args.first == "probe-storage-info" {
            guard args.count == 2, parseUInt32(args[1]) != 0 else {
                print("Usage: MTPProbe probe-storage-info <nonzero-storage-id>")
                exit(1)
            }
            return ("probe-storage-info", nil, parseUInt32(args[1]), 0x3000, nil, nil, [])
        }

        if args.first == "probe-diagnostic" {
            do {
                let options = try MTPDiagnosticOptions(arguments: Array(args.dropFirst()))
                return (options.traceStorageIDs ? "probe-diagnostic-trace" : "probe-diagnostic",
                        nil, 0, 0x3000, nil, nil, options.notes)
            } catch {
                print("Usage: MTPProbe probe-diagnostic [--trace-storage-ids [--note \"text\"]...]")
                exit(1)
            }
        }

        if args.isEmpty || args[0] == "probe" {
            return ("probe", nil, 0, 0x3000, nil, nil, [])
        }

        if args[0] == "--help" || args[0] == "-h" || args[0] == "help" {
            return ("help", nil, 0, 0x3000, nil, nil, [])
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

            return ("upload", filePath.map { URL(fileURLWithPath: $0) }, storageID, format, name, nil, [])
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
                outputPath.map { URL(fileURLWithPath: $0) },
                []
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
            return ("upload", URL(fileURLWithPath: filePath!), storageID, format, name, nil, [])
        }

        return ("probe", nil, 0, 0x3000, nil, nil, [])
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

func runDiscoveryProbe(diagnosticOnly: Bool = false, diagnosticStorageID: UInt32? = nil,
                       traceStorageIDs: Bool = false, notes: [String] = []) {
    let diagnostic = MTPDiagnosticReporting(enabled: traceStorageIDs)
    diagnostic.reportNotes(notes)
    print("AndroidMacBridge MTP Probe")
    print("==========================\n")
    print("Searching for MTP USB devices...")

    do {
        let target = try USBDeviceDiscovery.findUniqueTarget()
        let service = target.interfaceService
        defer { IOObjectRelease(service) }

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

        if diagnosticOnly {
            print("\nDiagnostic probe: daemon termination disabled.")
        } else {
            print("\nOpening USB interface without terminating applications...")
            print("Automatic daemon termination disabled.")
        }
        Thread.sleep(forTimeInterval: 1.0)

        print("\nEstablishing MTP session...")
        let device = try USBDeviceDiscovery.openTarget(target)
        try diagnostic.measure("OpenSession") { try device.openSession() }
        var closeAttempted = false
        defer {
            if !closeAttempted {
                do { try diagnostic.measure("CloseSession") { try device.closeSession() } }
                catch { print("Session cleanup failed: \(error)") }
            }
        }

        print("\nRetrieving basic device information...")
        let deviceInfo = try diagnostic.measure("GetDeviceInfo") { try device.getDeviceInfo() }
        diagnostic.reportEvents(deviceInfo.eventsSupported)
        print("Manufacturer: \(deviceInfo.manufacturer)")
        print("Model: \(deviceInfo.model)")
        print("Device Version: \(deviceInfo.deviceVersion)")

        print("\nEnumerating storage volumes...")
        let storageIDs = try diagnostic.measure("GetStorageIDs") {
            try device.getStorageIDs(onDiagnostic: traceStorageIDs ? { print($0.report) } : nil)
        }
        diagnostic.reportStorageResult(storageIDs)
        if storageIDs.isEmpty {
            if let historicalID = diagnosticStorageID {
                print("Empty enumeration: issuing one explicitly requested GetStorageInfo diagnostic")
                let info = try device.diagnoseStorageInfo(storageID: historicalID)
                print("GetStorageInfo diagnostic succeeded: ID 0x\(String(info.storageID, radix: 16)), capacity \(info.maxCapacity), free bytes \(info.freeSpaceInBytes), access \(info.accessCapability)")
            }
            throw diagnostic.emptyInventoryError
        }

        for id in storageIDs {
            let storageInfo = try diagnostic.measure("GetStorageInfo") { try device.getStorageInfo(storageID: id) }
            print("\n* \(storageInfo.displayName)")
            print("  ID: 0x\(String(id, radix: 16, uppercase: true))")
            print("  Capacity: \(storageInfo.capacityString)")
            print("  Free Space: \(storageInfo.freeString)")
            print("  Access: \(storageInfo.accessCapability == 0 ? "Read/Write" : "Read Only")")

            if diagnosticOnly { continue }

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

        closeAttempted = true
        try diagnostic.measure("CloseSession") { try device.closeSession() }
        print("\nMTP Probe complete.")
    } catch USBDiscoveryError.noDevicesFound {
        print("No MTP USB devices found. Please ensure an Android device is connected and unlocked in MTP (File Transfer) mode.")
        exit(1)
    } catch {
        print("Inventory failed: \(error)")
        exit(1)
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
        let target = try USBDeviceDiscovery.findUniqueTarget()
        let service = target.interfaceService
        defer { IOObjectRelease(service) }
        print("\nMTP interface detected")

        print("Automatic daemon termination disabled.")
        Thread.sleep(forTimeInterval: 1.0)

        let device = try USBDeviceDiscovery.openTarget(target)
        try device.openSession()
        var closeAttempted = false
        defer {
            if !closeAttempted {
                do { try device.closeSession() }
                catch { print("Session cleanup failed: \(error)") }
            }
        }

        let storageIDs = try device.getStorageIDs()
        guard !storageIDs.isEmpty else {
            print("No MTP storage volumes were found on the connected device.")
            throw MTPDeviceError.receiveDataFailed("Upload aborted before SendObject")
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
            throw MTPDeviceError.receiveDataFailed("Upload aborted before SendObject")
        }

        if storageID != 0 && !storageIDs.contains(storageID) {
            print("Requested storage ID 0x\(String(storageID, radix: 16, uppercase: true)) was not found. Available IDs: \(storageIDs.map { "0x\(String($0, radix: 16, uppercase: true))" }.joined(separator: ", "))")
            throw MTPDeviceError.receiveDataFailed("Upload aborted before SendObject")
        }

        print("\nUploading to storage 0x\(String(chosenStorageID, radix: 16, uppercase: true))")
        let result = try device.uploadFile(
            at: fileURL,
            storageID: chosenStorageID,
            parentHandle: 0xFFFFFFFF,
            filename: name ?? fileURL.lastPathComponent,
            format: format
        )

        closeAttempted = true
        try device.closeSession()

        print("\nUpload success: \(result.filename)")
        print("Object handle: 0x\(String(result.objectHandle, radix: 16, uppercase: true))")
        print("Storage ID: 0x\(String(chosenStorageID, radix: 16, uppercase: true))")
        print("Size: \(result.objectCompressedSize) bytes")

        print("\nMac → Samsung MTP transfer test complete.")
    } catch USBDiscoveryError.noDevicesFound {
        print("No MTP USB devices found. Please ensure the Samsung is connected and in File Transfer mode.")
        exit(1)
    } catch {
        print("Upload failed: \(error)")
        exit(1)
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
        let target = try USBDeviceDiscovery.findUniqueTarget()
        let service = target.interfaceService
        defer { IOObjectRelease(service) }
        print("\nMTP interface detected")

        print("Automatic daemon termination disabled.")
        Thread.sleep(forTimeInterval: 1.0)

        let device = try USBDeviceDiscovery.openTarget(target)
        try device.openSession()
        var closeAttempted = false
        defer {
            if !closeAttempted {
                do { try device.closeSession() }
                catch { print("Session cleanup failed: \(error)") }
            }
        }

        guard let handle = try findObjectHandle(on: device, filename: targetName) else {
            print("Object named \(targetName) was not found on the device.")
            return
        }

        print("Found object handle: 0x\(String(handle, radix: 16, uppercase: true))")
        print("GetObject (0x1009) ...")

        let payload = try device.getObject(handle: handle)
        try payload.write(to: destination)

        let originalData = try Data(contentsOf: originalURL)
        let originalHash = SHA256.hash(data: originalData).map { String(format: "%02x", $0) }.joined()
        let downloadedHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        closeAttempted = true
        try device.closeSession()

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

func runRootMetadata() {
    do {
        let target = try USBDeviceDiscovery.findUniqueTarget()
        defer { IOObjectRelease(target.interfaceService) }
        print("Root diagnostic: unique Samsung 04E8:6860 / 06/01/01 selected; no daemon termination")
        Thread.sleep(forTimeInterval: 1.0) // Existing pre-session delay preserved.
        let device = try USBDeviceDiscovery.openTarget(target)
        let result = try MTPRootListing.run(device: device)
        // JSON escapes control characters. Only directory names are disclosed;
        // file names, dates, sizes, keywords and other personal metadata are omitted.
        let entries: [[String: Any]] = result.entries.map { info in
            var row: [String: Any] = ["handle": info.objectHandle, "format": info.objectFormat,
                                     "parent": info.parentObject, "type": info.isDirectory ? "directory" : "file"]
            if info.isDirectory { row["name"] = info.filename }
            return row
        }
        let output: [String: Any] = ["storageID": result.storageID, "totalRootHandles": result.totalHandles,
                                    "inspected": entries.count, "complete": result.complete, "entries": entries]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print("ROOT_METADATA " + String(decoding: data, as: UTF8.self))
        print("Root diagnostic complete; session closed")
    } catch {
        print("Root diagnostic failed: \(error)")
        exit(1)
    }
}

func runFolderBrowserVerification() {
    let browser = MTPFolderBrowser()
    var closed = false
    defer { if !closed { do { try browser.close() } catch { print("Browser cleanup failed: \(error)") } } }
    do {
        let target = try USBDeviceDiscovery.findUniqueTarget()
        defer { IOObjectRelease(target.interfaceService) }
        print("Browser diagnostic: unique Samsung 04E8:6860; metadata only; existing one-second delay")
        Thread.sleep(forTimeInterval: 1.0)
        let device = try USBDeviceDiscovery.openTarget(target)
        let start = try browser.start(MTPDeviceBrowserSession(device: device))
        if start.storageState == .emptySuccess {
            print("STORAGE_STATE " + (try start.presentation()))
            print(start.storageState.message)
            try browser.close(); closed = true; return
        }
        let internalStores = start.storages.filter { $0.type == 3 }
        guard internalStores.count == 1 else { throw MTPFolderBrowser.Failure.invalidStorage }
        func complete(_ initial: MTPFolderBrowser.Snapshot) throws -> MTPFolderBrowser.Snapshot {
            guard initial.total <= 256 else { throw MTPFolderBrowser.Failure.limitExceeded }
            var current = initial
            print("BROWSER " + (try current.presentation()))
            while current.more {
                current = try browser.loadMore()
                print("BROWSER " + (try current.presentation()))
            }
            guard current.phase == .completed else { throw MTPFolderBrowser.Failure.invalidMetadata }
            return current
        }
        let root = try complete(browser.root(internalStores[0]))
        guard let directory = root.entries.filter({$0.directory}).min(by: {$0.id.handle < $1.id.handle}) else {
            throw MTPFolderBrowser.Failure.invalidDirectory
        }
        print("Selected directory handle: \(directory.id.handle)")
        _ = try complete(browser.open(directory.id))
        // Back performs one fresh root query and at most one metadata batch.
        let back = try browser.back()
        guard back.directory?.handle == nil else { throw MTPFolderBrowser.Failure.invalidDirectory }
        print("BROWSER_BACK " + (try back.presentation()))
        try browser.close(); closed = true
        do {
            _ = try browser.open(directory.id)
            throw MTPParseError.malformed("Stale identity unexpectedly accepted")
        } catch MTPFolderBrowser.Failure.staleIdentity {
            print("Browser verification complete: clean close; old handle rejected without USB I/O")
        }
    } catch {
        if error is USBDiscoveryFailure { browser.discoveryFailed(error) }
        print("STORAGE_STATE " + ((try? browser.snapshot.presentation()) ?? "{}"))
        // exit() does not run function defers; explicitly close before returning failure.
        if !closed { do { try browser.close() } catch { print("Browser cleanup failed: \(error)") }; closed = true }
        print("Browser diagnostic failed: \(error)")
        exit(1)
    }
}

func runManualStorageRefresh() {
    let browser = MTPFolderBrowser()
    defer {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(browser.refreshObservations) {
            print("REFRESH_OBSERVATIONS " + String(decoding: data, as: UTF8.self))
        }
    }
    var started = false
    do {
        let target = try USBDeviceDiscovery.findUniqueTarget()
        defer { IOObjectRelease(target.interfaceService) }
        print("Manual refresh diagnostic: Samsung 04E8:6860; metadata only; one-second pre-session delay")
        Thread.sleep(forTimeInterval: 1.0)
        let device = try USBDeviceDiscovery.openTarget(target)
        started = true
        let initial = try browser.start(MTPDeviceBrowserSession(device: device))
        print("STORAGE_STATE " + (try initial.presentation()))
        print(initial.storageState.message)
        print("AWAITING_MANUAL_REFRESH: enter refresh followed by newline once; no automatic retry")
        fflush(stdout)
        let action = try FileHandle.standardInput.read(upToCount: 8) ?? Data()
        guard action == Data("refresh\n".utf8) else {
            browser.cancel()
            print("STORAGE_STATE " + (try browser.snapshot.presentation()))
            return
        }
        let result = try browser.refreshStorage()
        print("STORAGE_STATE " + (try result.presentation()))
        print(result.storageState.message)
        try browser.close()
        print("Manual refresh complete; session closed")
    } catch {
        if !started { browser.discoveryFailed(error) }
        print("STORAGE_STATE " + ((try? browser.snapshot.presentation()) ?? "{}"))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(browser.refreshObservations) { print("REFRESH_OBSERVATIONS " + String(decoding: data, as: UTF8.self)) }
        print("Manual refresh diagnostic failed: \(error)")
        do { try browser.close() } catch { print("Refresh cleanup failed: \(error)") }
        exit(1)
    }
}

let cli = MTPProbeCLI.parse(CommandLine.arguments)

switch cli.mode {
case "probe-storage-refresh":
    runManualStorageRefresh()
case "probe-folder-browser":
    runFolderBrowserVerification()
case "probe-root-metadata":
    runRootMetadata()
case "probe-storage-info":
    runDiscoveryProbe(diagnosticOnly: true, diagnosticStorageID: cli.storageID)
case "probe-diagnostic":
    runDiscoveryProbe(diagnosticOnly: true)
case "probe-diagnostic-trace":
    runDiscoveryProbe(diagnosticOnly: true, traceStorageIDs: true, notes: cli.notes)
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
