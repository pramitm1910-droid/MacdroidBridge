import Foundation
import CoreFoundation

/// Pure registry-descriptor policy. Never opens USB or issues protocol commands.
public enum USBTargetSelection {
    public enum Rejection: Error, Equatable {
        case malformedDescriptor, noTarget, multipleTargets, noInterface
        case competingInterface, unexpectedDescriptor, identityChanged
    }
    public struct Device {
        public let id: UInt64
        public let vendor: Int
        public let product: Int
        public init(id: UInt64, properties: [String: Any]) throws {
            guard id != 0 else { throw Rejection.malformedDescriptor }
            self.id = id
            vendor = try integer(properties, "idVendor", maximum: 65535)
            product = try integer(properties, "idProduct", maximum: 65535)
        }
    }
    public struct Interface {
        public let id: UInt64
        public let deviceID: UInt64
        public let number: Int
        public let interfaceClass: Int
        public let subclass: Int
        public let protocolCode: Int
        public let advertisedVendor: Int?
        public let advertisedProduct: Int?
        public init(id: UInt64, deviceID: UInt64, properties: [String: Any]) throws {
            guard id != 0, deviceID != 0 else { throw Rejection.malformedDescriptor }
            self.id = id; self.deviceID = deviceID
            number = try integer(properties, "bInterfaceNumber", maximum: 255)
            interfaceClass = try integer(properties, "bInterfaceClass", maximum: 255)
            subclass = try integer(properties, "bInterfaceSubClass", maximum: 255)
            protocolCode = try integer(properties, "bInterfaceProtocol", maximum: 255)
            advertisedVendor = try properties["idVendor"].map { _ in try integer(properties, "idVendor", maximum: 65535) }
            advertisedProduct = try properties["idProduct"].map { _ in try integer(properties, "idProduct", maximum: 65535) }
        }
    }
    public struct Selection: Equatable {
        public let deviceID: UInt64
        public let interfaceID: UInt64
        public let interfaceNumber: Int
    }
    private static func integer(_ properties: [String: Any], _ key: String, maximum: Int) throws -> Int {
        guard let n = properties[key] as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0,
              n.doubleValue <= Double(maximum), n.doubleValue.rounded() == n.doubleValue else {
            throw Rejection.malformedDescriptor
        }
        return n.intValue
    }
    public static func select(devices: [Device], interfaces: [Interface]) throws -> Selection {
        guard Set(devices.map(\.id)).count == devices.count,
              Set(interfaces.map(\.id)).count == interfaces.count else { throw Rejection.malformedDescriptor }
        let targets = devices.filter { $0.vendor == 0x04E8 && $0.product == 0x6860 }
        guard !targets.isEmpty else { throw Rejection.noTarget }
        guard targets.count == 1 else { throw Rejection.multipleTargets }
        let target = targets[0]
        // The registry adapter supplies all image-class interfaces, including
        // competing PTP devices. No enumeration order or fallback is accepted.
        guard !interfaces.isEmpty else { throw Rejection.noInterface }
        guard interfaces.count == 1 else { throw Rejection.competingInterface }
        let interface = interfaces[0]
        guard interface.deviceID == target.id else { throw Rejection.competingInterface }
        guard interface.interfaceClass == 6, interface.subclass == 1, interface.protocolCode == 1 else {
            throw Rejection.unexpectedDescriptor
        }
        guard interface.advertisedVendor.map({ $0 == target.vendor }) ?? true,
              interface.advertisedProduct.map({ $0 == target.product }) ?? true else {
            throw Rejection.identityChanged
        }
        return Selection(deviceID: target.id, interfaceID: interface.id, interfaceNumber: interface.number)
    }
    /// The opening callback is never reached for missing, changed or ambiguous identity.
    public static func withSelection<T>(devices: [Device], interfaces: [Interface],
                                        expected: Selection? = nil,
                                        open: (Selection) throws -> T) throws -> T {
        let selected = try select(devices: devices, interfaces: interfaces)
        guard expected == nil || expected == selected else { throw Rejection.identityChanged }
        return try open(selected)
    }
}
