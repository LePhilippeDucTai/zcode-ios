import Foundation
import Testing
import ZCodeWire

struct JSONValuePerformanceTests {
    /// Environ 4,6 Mo de JSON au format d'un snapshot : 2 000 lignes d'environ 2,3 Ko de texte.
    static let bigSnapshot: Data = {
        let text = String(repeating: "Réponse longue 🌍 ", count: 110)
        var rows: [String] = []
        rows.reserveCapacity(2_000)
        for index in 0..<2_000 {
            rows.append(#"{"rowId":\#(index),"kind":"assistantText","state":"complete","createdAt":1791886892334,"text":"\#(text)","actions":{"canFork":true}}"#)
        }
        let json = #"{"rows":{"window":[\#(rows.joined(separator: ","))],"totalCount":2000,"firstRowId":0},"goal":null}"#
        return Data(json.utf8)
    }()

    @Test func decodeUnGrosSnapshotEnMoinsDUneSeconde() throws {
        let data = Self.bigSnapshot
        #expect(data.count > 4_000_000)
        var value = JSONValue.null
        let elapsed = try ContinuousClock().measure {
            value = try JSONValue.decode(data)
        }
        #expect(value["rows"]?["window"]?.arrayValue?.count == 2_000)
        #expect(value["rows"]?["window"]?.arrayValue?.first?["createdAt"] == .number(1_791_886_892_334))
        #expect(value["goal"] == .null)
        #expect(elapsed < .seconds(1), "décodage de \(data.count) octets en \(elapsed)")
    }
}
