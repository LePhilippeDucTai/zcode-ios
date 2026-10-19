import Foundation
import Testing
import ZCodeTestSupport
import ZCodeWire

struct GoldenVector: Sendable, CustomTestStringConvertible {
    let name: String
    let value: RPCValue
    let hex: String
    var testDescription: String { name }

    static let all: [GoldenVector] = [
        .init(name: "undefined", value: .undefined, hex: "00"),
        .init(name: "chaîne vide", value: .string(""), hex: "0100"),
        .init(name: "hello", value: .string("hello"), hex: "010568656c6c6f"),
        .init(name: "unicode", value: .string("é🌍"), hex: "0106c3a9f09f8c8d"),
        .init(name: "int 0", value: .int(0), hex: "0600"),
        .init(name: "int 1", value: .int(1), hex: "0601"),
        .init(name: "int 127", value: .int(127), hex: "067f"),
        .init(name: "int 128", value: .int(128), hex: "068001"),
        .init(name: "int 300", value: .int(300), hex: "06ac02"),
        .init(name: "int 65535", value: .int(65535), hex: "06ffff03"),
        .init(name: "int -1", value: .int(-1), hex: "06ffffffff0f"),
        .init(name: "int max", value: .int(.max), hex: "06ffffffff07"),
        .init(name: "int min", value: .int(.min), hex: "068080808008"),
        .init(name: "flottant", value: .json(.number(3.5)), hex: "0503332e35"),
        .init(name: "true", value: .json(.bool(true)), hex: "050474727565"),
        .init(name: "false", value: .json(.bool(false)), hex: "050566616c7365"),
        .init(name: "null", value: .json(.null), hex: "05046e756c6c"),
        .init(name: "tableau vide", value: .array([]), hex: "0400"),
        .init(name: "tableau", value: .array([.int(1), .string("a")]), hex: "04020601010161"),
        .init(name: "imbriqué", value: .array([.int(1), .array([.int(2)]), .string("x")]),
              hex: "0403060104010602010178"),
        .init(name: "objet", value: .json(.object(["a": .number(1), "b": .string("two")])),
              hex: "05117b2261223a312c2262223a2274776f227d"),
        .init(name: "Uint8Array", value: .buffer(Data([1, 2, 3])), hex: "0203010203"),
        .init(name: "VSBuffer", value: .vsBuffer(Data("hi".utf8)), hex: "03026869"),
        .init(name: "entier hors int32", value: .json(.number(2_147_483_648)),
              hex: "050a32313437343833363438"),
    ]
}

struct RPCSerializerTests {
    @Test(arguments: GoldenVector.all)
    func encodeCommeLeSerialiseurTypeScript(_ vector: GoldenVector) {
        #expect(RPCSerializer.encode(vector.value).hex == vector.hex)
    }

    @Test(arguments: GoldenVector.all)
    func decodeLesOctetsDuSerialiseurTypeScript(_ vector: GoldenVector) throws {
        var reader = RPCReader(Data(hex: vector.hex))
        #expect(try reader.decode() == vector.value)
        #expect(reader.isAtEnd)
    }

    @Test func encodeUnMessageCompletEnTeteEtCorps() {
        let message = RPCSerializer.encode(
            .array([.int(100), .int(0), .string("zcode-agent"), .string("helloConversationV4")]),
            .array([])
        )
        #expect(message.hex == "040406640600010b7a636f64652d6167656e74011368656c6c6f436f6e766572736174696f6e56340400")
    }

    @Test func convertitLeJSONCommeSerializeEnJavaScript() {
        #expect(RPCValue(.string("é")) == .string("é"))
        #expect(RPCValue(.number(-1)) == .int(-1))
        #expect(RPCValue(.number(3.5)) == .json(.number(3.5)))
        #expect(RPCValue(.number(1_791_885_492_501)) == .json(.number(1_791_885_492_501)))
        #expect(RPCValue(.array([.number(1), .string("a")])) == .array([.int(1), .string("a")]))
        #expect(RPCValue(.bool(true)) == .json(.bool(true)))
        #expect(RPCValue(.null) == .json(.null))
        #expect(RPCValue(.object(["k": .number(1)])) == .json(.object(["k": .number(1)])))
    }

    @Test func vueJSON() {
        #expect(RPCValue.undefined.jsonValue == nil)
        #expect(RPCValue.int(42).jsonValue == .number(42))
        #expect(RPCValue.buffer(Data([0xff, 0x00])).jsonValue == .string("/wA="))
        #expect(RPCValue.array([.int(1), .undefined]).jsonValue == .array([.number(1), .null]))
    }

    @Test func conserveLeMarqueurDOctetsImbriques() throws {
        // { data: Uint8Array([255, 0]) } côté TypeScript : le marqueur reste un objet JSON en Swift.
        var reader = RPCReader(Data(hex: "05427b2264617461223a7b225f5f7a636f64655f7270635f6e65737465645f75696e743861727261795f7631223a747275652c22626173653634223a222f77413d227d7d"))
        let value = try reader.decode()
        #expect(value.jsonValue?["data"]?["base64"]?.stringValue == "/wA=")
    }

    @Test func signaleLesDonneesInvalides() {
        func decode(_ hex: String) throws(RPCDecodingError) -> RPCValue {
            var reader = RPCReader(Data(hex: hex))
            return try reader.decode()
        }
        #expect(throws: RPCDecodingError.truncated) { try decode("") }
        #expect(throws: RPCDecodingError.unknownTag(7)) { try decode("07") }
        #expect(throws: RPCDecodingError.truncated) { try decode("01056865") }
        #expect(throws: RPCDecodingError.malformedVQL) { try decode("06ffffffffff") }
        #expect(throws: RPCDecodingError.invalidJSON) { try decode("05037b7b7b") }
    }
}
