import Foundation
import Testing
import ZCodeTestSupport
import ZCodeWire

struct FramesTests {
    let helloRequest = Data(hex: "040406640600010b7a636f64652d6167656e74011368656c6c6f436f6e766572736174696f6e56340400")

    @Test func encadreUnMessageCommeSocketProtocol() {
        #expect(FrameCodec.encodeRegular(helloRequest).hex
            == "0100000000000000000000002a" + helloRequest.hex)
    }

    @Test func extraitLaReponseInitialize() throws {
        var decoder = FrameDecoder()
        let payloads = try decoder.append(Data(hex: "01000000000000000000000006040106c80100"))
        #expect(payloads == [Data(hex: "040106c80100")])
    }

    @Test func separeDeuxTramesRecuesEnsemble() throws {
        var decoder = FrameDecoder()
        let chunk = FrameCodec.encodeRegular(Data([1])) + FrameCodec.encodeRegular(Data([2, 3]))
        #expect(try decoder.append(chunk) == [Data([1]), Data([2, 3])])
    }

    @Test func reassembleUneTrameRecueOctetParOctet() throws {
        var decoder = FrameDecoder()
        let frame = FrameCodec.encodeRegular(helloRequest)
        for byte in frame.dropLast() {
            #expect(try decoder.append(Data([byte])) == [])
        }
        #expect(try decoder.append(Data([frame.last!])) == [helloRequest])
    }

    @Test func emetUneChargeVidePourUneTrameRegularVide() throws {
        var decoder = FrameDecoder()
        #expect(try decoder.append(FrameCodec.encodeRegular(Data())) == [Data()])
    }

    @Test func ignoreLesTramesNonRegular() throws {
        var decoder = FrameDecoder()
        let keepAlive = Data(hex: "09 00000000 00000000 00000002 abcd")
        let chunk = keepAlive + FrameCodec.encodeRegular(Data([7]))
        #expect(try decoder.append(chunk) == [Data([7])])
    }

    @Test func refuseUneTrameTropGrande() {
        var decoder = FrameDecoder(maximumPayloadSize: 16)
        #expect(throws: FrameDecodingError.frameTooLarge(17)) {
            try decoder.append(Data(hex: "01 00000000 00000000 00000011"))
        }
    }

    @Test func grosseChargeEnMorceaux() throws {
        var decoder = FrameDecoder()
        let payload = Data((0..<(2 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        let frame = FrameCodec.encodeRegular(payload)
        var received: [Data] = []
        var offset = 0
        while offset < frame.count {
            let end = min(offset + 65_536, frame.count)
            received += try decoder.append(frame[offset..<end])
            offset = end
        }
        #expect(received == [payload])
    }
}
