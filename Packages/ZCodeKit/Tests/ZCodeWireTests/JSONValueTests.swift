import Foundation
import Testing
import ZCodeWire

struct JSONValueTests {
    @Test func decodeLesFragmentsDeRacine() throws {
        #expect(try JSONValue.decode(Data("true".utf8)) == .bool(true))
        #expect(try JSONValue.decode(Data("3.5".utf8)) == .number(3.5))
        #expect(try JSONValue.decode(Data("null".utf8)) == .null)
        #expect(try JSONValue.decode(Data("\"é🌍\"".utf8)) == .string("é🌍"))
    }

    @Test func neConfondPasNombreEtBooleen() throws {
        #expect(try JSONValue.decode(Data("[1,true,0,false]".utf8))
            == .array([.number(1), .bool(true), .number(0), .bool(false)]))
    }

    @Test func encodeEnJSONCompactAvecClesTriees() throws {
        let value: JSONValue = .object(["b": .string("x/y"), "a": .string("é"), "n": .number(1)])
        #expect(String(decoding: try value.jsonData(), as: UTF8.self) == #"{"a":"é","b":"x/y","n":1}"#)
    }

    @Test func conserveLesHorodatagesEnMillisecondes() throws {
        let value = try JSONValue.decode(Data("1791885492501".utf8))
        #expect(value == .number(1_791_885_492_501))
        #expect(String(decoding: try value.jsonData(), as: UTF8.self) == "1791885492501")
    }

    @Test func accesseurs() throws {
        let value = try JSONValue.decode(Data(#"{"s":"t","n":2,"b":false,"a":[1],"o":{}}"#.utf8))
        #expect(value["s"]?.stringValue == "t")
        #expect(value["n"]?.numberValue == 2)
        #expect(value["b"]?.boolValue == false)
        #expect(value["a"]?.arrayValue == [.number(1)])
        #expect(value["o"]?.objectValue == [:])
        #expect(value["absent"] == nil)
        #expect(JSONValue.string("x")["s"] == nil)
    }
}
