import Foundation

public enum MTPStorageDiscoveryState: String, Codable {
    case available, emptySuccess, deviceUnavailable, transportFailure, disconnected, cancelled
    public var message: String {
        switch self {
        case .available: return "Storage is available."
        case .emptySuccess: return "The phone reported no available storage."
        case .deviceUnavailable: return "No matching Samsung device or eligible interface is available."
        case .transportFailure: return "Storage discovery failed; diagnostic error details are available."
        case .disconnected: return "The MTP session is no longer valid."
        case .cancelled: return "The operation was cancelled."
        }
    }
    public static func classify(_ error: Error) -> Self {
        if let failure = error as? USBDiscoveryFailure,
           failure.stage == .interfaceValidation,
           ["noTarget", "noInterface"].contains(failure.detail) { return .deviceUnavailable }
        if let rejection = error as? USBTargetSelection.Rejection,
           rejection == .noTarget || rejection == .noInterface { return .deviceUnavailable }
        if case MTPDeviceError.deviceDisconnected = error { return .disconnected }
        return .transportFailure
    }
}

public struct MTPStorageRefreshObservation: Codable {
    public let timestamp: Date
    public let sessionGeneration: UUID
    public let mechanism: String
    public let result: MTPStorageDiscoveryState
    public let returnedStorageCount: Int?
    public let failureCategory: String?
    public let annotation: String?
}
