import Foundation
import Testing
@testable import OpenIslandCore

struct CodexWebSocketCodecTests {
    @Test
    func maskedClientFrameRoundTripsThroughDecoder() throws {
        let payload = Data(#"{"id":2,"method":"thread/list"}"#.utf8)
        let encoded = CodexWebSocketCodec.clientFrame(
            opcode: 0x1,
            payload: payload,
            maskingKey: [0x12, 0x34, 0x56, 0x78]
        )
        var buffer = encoded

        let frames = try CodexWebSocketCodec.decodeFrames(from: &buffer)

        #expect(frames.count == 1)
        #expect(frames[0].opcode == 0x1)
        #expect(frames[0].payload == payload)
        #expect(buffer.isEmpty)
    }

    @Test
    func decoderWaitsForCompleteExtendedLengthFrame() throws {
        let payload = Data(repeating: 0x61, count: 512)
        let encoded = CodexWebSocketCodec.serverFrame(opcode: 0x1, payload: payload)
        var buffer = Data(encoded.prefix(100))

        #expect(try CodexWebSocketCodec.decodeFrames(from: &buffer).isEmpty)

        buffer.append(encoded.dropFirst(100))
        let frames = try CodexWebSocketCodec.decodeFrames(from: &buffer)
        #expect(frames.map(\.payload) == [payload])
    }
}
