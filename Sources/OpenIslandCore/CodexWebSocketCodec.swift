import Foundation

enum CodexWebSocketCodec {
    struct Frame: Equatable {
        let isFinal: Bool
        let opcode: UInt8
        let payload: Data
    }

    enum CodecError: Error {
        case frameTooLarge
        case malformedFrame
    }

    static let maximumPayloadBytes = 8 * 1_024 * 1_024

    static func clientFrame(
        opcode: UInt8,
        payload: Data,
        maskingKey: [UInt8]? = nil
    ) -> Data {
        let key = maskingKey ?? (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        precondition(key.count == 4)
        return frame(opcode: opcode, payload: payload, maskingKey: key)
    }

    static func serverFrame(opcode: UInt8, payload: Data) -> Data {
        frame(opcode: opcode, payload: payload, maskingKey: nil)
    }

    static func decodeFrames(from buffer: inout Data) throws -> [Frame] {
        var frames: [Frame] = []

        while buffer.count >= 2 {
            let first = buffer[buffer.startIndex]
            let second = buffer[buffer.index(after: buffer.startIndex)]
            let isFinal = first & 0x80 != 0
            let opcode = first & 0x0F
            let isMasked = second & 0x80 != 0
            var payloadLength = UInt64(second & 0x7F)
            var cursor = 2

            if payloadLength == 126 {
                guard buffer.count >= cursor + 2 else { break }
                payloadLength = UInt64(buffer[cursor]) << 8 | UInt64(buffer[cursor + 1])
                cursor += 2
            } else if payloadLength == 127 {
                guard buffer.count >= cursor + 8 else { break }
                payloadLength = 0
                for offset in 0..<8 {
                    payloadLength = payloadLength << 8 | UInt64(buffer[cursor + offset])
                }
                cursor += 8
            }

            guard payloadLength <= maximumPayloadBytes else {
                throw CodecError.frameTooLarge
            }

            var maskingKey: [UInt8] = []
            if isMasked {
                guard buffer.count >= cursor + 4 else { break }
                maskingKey = Array(buffer[cursor..<(cursor + 4)])
                cursor += 4
            }

            let payloadCount = Int(payloadLength)
            guard buffer.count >= cursor + payloadCount else { break }
            var payload = Data(buffer[cursor..<(cursor + payloadCount)])
            if isMasked {
                for offset in payload.indices {
                    payload[offset] ^= maskingKey[offset % 4]
                }
            }

            frames.append(Frame(isFinal: isFinal, opcode: opcode, payload: payload))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + cursor + payloadCount))
        }

        return frames
    }

    private static func frame(opcode: UInt8, payload: Data, maskingKey: [UInt8]?) -> Data {
        var result = Data([0x80 | (opcode & 0x0F)])
        let maskFlag: UInt8 = maskingKey == nil ? 0 : 0x80

        switch payload.count {
        case 0...125:
            result.append(maskFlag | UInt8(payload.count))
        case 126...65_535:
            result.append(maskFlag | 126)
            result.append(UInt8((payload.count >> 8) & 0xFF))
            result.append(UInt8(payload.count & 0xFF))
        default:
            result.append(maskFlag | 127)
            let count = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                result.append(UInt8((count >> UInt64(shift)) & 0xFF))
            }
        }

        guard let maskingKey else {
            result.append(payload)
            return result
        }

        result.append(contentsOf: maskingKey)
        for (offset, byte) in payload.enumerated() {
            result.append(byte ^ maskingKey[offset % 4])
        }
        return result
    }
}
