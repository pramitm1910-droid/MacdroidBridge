import Foundation
import Darwin

/// Only operation names and OS errors are reported; never registry property values.
public struct USBDiscoveryFailure: Error, CustomStringConvertible {
    public enum Stage: String { case queryCreation, iteratorAcquisition, iteratorTraversal, descriptorAccess, interfaceValidation }
    public let stage: Stage
    public let operation: String
    public let code: Int32?
    public let detail: String
    public init(_ stage: Stage, _ operation: String, code: Int32? = nil, detail: String) {
        self.stage = stage; self.operation = operation; self.code = code; self.detail = detail
    }
    public var description: String {
        let status: String
        if let code {
            let name = mach_error_string(code).map { String(cString: $0) } ?? "unknown OS error"
            status = String(format: "0x%08X", UInt32(bitPattern: code)) + " (" + name + ")"
        } else { status = "unavailable: this API/validation supplies no separate error code" }
        return "USB discovery [\(stage.rawValue)] \(operation): \(detail); code=\(status)"
    }
}

public enum USBDiscoveryDiagnostics {
    public static func require(_ condition: Bool, stage: USBDiscoveryFailure.Stage, operation: String,
                               code: Int32? = nil, detail: String) throws {
        guard condition else { throw USBDiscoveryFailure(stage, operation, code: code, detail: detail) }
    }
    /// Handles are supplied by adapters. Tests supply integers and never call IOKit.
    /// Owns every returned iterator/service until body returns or throws.
    public static func withServices<T>(query: String, acquire: () -> (Int32, UInt32),
                                       next: (UInt32) -> UInt32, isValid: (UInt32) -> Bool,
                                       release: (UInt32) -> Void, body: ([UInt32]) throws -> T) throws -> T {
        let (code, iterator) = acquire()
        defer { if iterator != 0 { release(iterator) } }
        try require(code == 0, stage: .iteratorAcquisition, operation: query + "/IOServiceGetMatchingServices",
                    code: code, detail: "matching-service acquisition failed")
        // IOKitLib.h explicitly defines success + NULL as no matching services.
        // There is no iterator to advance, validate or release in this case.
        if iterator == 0 { return try body([]) }
        var services: [UInt32] = []
        defer { services.forEach(release) }
        while true {
            let service = next(iterator)
            if service == 0 {
                try require(isValid(iterator), stage: .iteratorTraversal, operation: query + "/IOIteratorNext+IOIteratorIsValid",
                            detail: "iterator invalidated; IOIteratorNext returned zero without a separate status")
                break
            }
            services.append(service)
        }
        return try body(services)
    }
    public static func descriptors<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as USBTargetSelection.Rejection {
            throw USBDiscoveryFailure(.descriptorAccess, "descriptor decoding", detail: String(describing: error))
        }
    }
    public static func selection<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as USBTargetSelection.Rejection {
            throw USBDiscoveryFailure(.interfaceValidation, "target policy/pre-open identity", detail: String(describing: error))
        }
    }
}
