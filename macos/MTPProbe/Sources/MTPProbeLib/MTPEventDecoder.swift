import Foundation

struct MTPEvent: Equatable {
    let code: UInt16
    let transactionID: UInt32
    let parameters: [UInt32]
}

/// Independent event framing, never connected to bulk transaction state.
/// Standard USB event containers have a 12-byte header and up to three parameters.
struct MTPEventDecoder {
    enum Failure: Error, Equatable {
        case invalidLength, invalidType, inputTooLarge, poisoned
    }
    static let maximumContainerBytes = 24
    static let maximumInputBytes = 4096
    private var buffer = Data()
    private var failed = false
    var bufferedByteCount: Int { buffer.count }

    mutating func feed(_ input: Data) throws -> [MTPEvent] {
        guard !failed else { throw Failure.poisoned }
        do {
            guard input.count <= Self.maximumInputBytes else { throw Failure.inputTooLarge }
            var events: [MTPEvent] = []
            for byte in input {
                buffer.append(byte)
                guard buffer.count >= 4 else { continue }
                let length = Int(u32(0))
                guard length >= 12, length <= Self.maximumContainerBytes,
                      (length - 12) % 4 == 0 else { throw Failure.invalidLength }
                if buffer.count >= 6, u16(4) != 4 { throw Failure.invalidType }
                if buffer.count == length {
                    events.append(MTPEvent(code: u16(6), transactionID: u32(8),
                                           parameters: stride(from: 12, to: length, by: 4).map { u32($0) }))
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            return events
        } catch {
            failed = true
            buffer.removeAll(keepingCapacity: false)
            throw error
        }
    }

    private func u16(_ offset: Int) -> UInt16 {
        UInt16(buffer[offset]) | UInt16(buffer[offset + 1]) << 8
    }

    private func u32(_ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(buffer[offset + $1]) << ($1 * 8) }
    }
}
