import Foundation

/// Parses only probe-diagnostic options. Note values are opaque, ordered strings.
public struct MTPDiagnosticOptions {
    public let traceStorageIDs: Bool
    public let notes: [String]

    public enum ParseError: Error {
        case invalidArguments
    }

    public init(arguments: [String]) throws {
        var trace = false
        var notes: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--trace-storage-ids" where !trace:
                trace = true
                index += 1
            case "--note":
                guard index + 1 < arguments.count else { throw ParseError.invalidArguments }
                notes.append(arguments[index + 1])
                index += 2
            default:
                throw ParseError.invalidArguments
            }
        }
        guard trace || notes.isEmpty else { throw ParseError.invalidArguments }
        self.traceStorageIDs = trace
        self.notes = notes
    }
}

/// Clocks are separate so wall-clock adjustments cannot change measured durations.
public struct MTPDiagnosticClock {
    public let wallNow: () -> Date
    public let monotonicNow: () -> TimeInterval

    public init(wallNow: @escaping () -> Date = { Date() },
                monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.wallNow = wallNow
        self.monotonicNow = monotonicNow
    }
}

/// Reporting only: invokes an operation once and preserves its result or error.
public struct MTPDiagnosticReporting {
    public let enabled: Bool
    private let clock: MTPDiagnosticClock
    private let emit: (String) -> Void

    public init(enabled: Bool, clock: MTPDiagnosticClock = MTPDiagnosticClock(),
                emit: @escaping (String) -> Void = { print($0) }) {
        self.enabled = enabled
        self.clock = clock
        self.emit = emit
    }

    public func measure<T>(_ operation: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startWall = clock.wallNow()
        let start = clock.monotonicNow()
        emit("\(operation) started: \(formatter.string(from: startWall))")
        var succeeded = false
        defer {
            let elapsed = clock.monotonicNow() - start
            let endWall = clock.wallNow()
            emit("\(operation) ended: \(formatter.string(from: endWall)); elapsed: \(String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), elapsed)) s; \(succeeded ? "completed" : "failed")")
        }
        let result = try body()
        succeeded = true
        return result
    }

    public func reportEvents(_ codes: [UInt16]) {
        guard enabled else { return }
        let names: [UInt16: String] = [
            0x4004: "StoreAdded", 0x4005: "StoreRemoved", 0x400C: "StorageInfoChanged"
        ]
        let entries = codes.map { code in
            String(format: "0x%04X", code) + (names[code].map { " (\($0))" } ?? "")
        }
        emit("GetDeviceInfo EventsSupported: \(entries.isEmpty ? "(none)" : entries.joined(separator: ", "))")
    }

    public func reportNotes(_ notes: [String]) {
        guard enabled else { return }
        for note in notes { emit("note: " + note) }
    }

    /// A successful getStorageIDs return has already validated the OK response.
    public func reportStorageResult(_ ids: [UInt32]) {
        guard enabled, ids.isEmpty else { return }
        emit("result: empty-success (0x2001, count 0)")
    }

    /// Called only after getStorageIDs successfully returned an empty array.
    /// The CLI still throws this error and exits 1 for unavailable inventory.
    public var emptyInventoryError: MTPDeviceError {
        .receiveDataFailed(enabled
            ? "valid empty storage response; no storage published (MTP 0x2001 OK). Inventory unavailable."
            : "GetStorageIDs returned zero IDs. Inventory unavailable; check that the phone is unlocked and file access is allowed.")
    }
}
