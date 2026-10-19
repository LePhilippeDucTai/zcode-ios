import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

private struct Couleur: OpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static let rouge = Couleur(rawValue: "rouge")
}

private struct Boite: Codable, Equatable {
    let couleur: Couleur
    let taille: Int
    let note: String?
}

struct FoundationsTests {
    @Test func enumerationOuverteConserveLesValeursInconnues() throws {
        let boite = try V4JSON.decode(Boite.self, from: .object([
            "couleur": .string("fuchsia"), "taille": .number(3), "inconnu": .bool(true),
        ]))
        #expect(boite.couleur.rawValue == "fuchsia")
        #expect(boite.couleur != .rouge)
        #expect(boite.taille == 3)
        #expect(boite.note == nil)
        #expect(try V4JSON.encode(Couleur.rouge) == .string("rouge"))
        #expect("\(Couleur.rouge)" == "rouge")
    }

    @Test func entiersExactsEtHorodatages() throws {
        struct Horodatage: Decodable { let at: Int64 }
        #expect(try V4JSON.decode(Horodatage.self, from: .object(["at": .number(1_791_886_864_067)])).at == 1_791_886_864_067)
        #expect(V4JSON.integer(.number(42)) == 42)
        #expect(V4JSON.integer(.number(4.5)) == nil)
        #expect(V4JSON.integer(.string("4")) == nil)
        #expect(V4JSON.integer(nil) == nil)
    }

    @Test func crc32ConformeAuVecteurStandard() {
        #expect(CRC32.hex(Array("123456789".utf8)) == "cbf43926")
        #expect(CRC32.hex([UInt8]()) == "00000000")
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func base64Strict() {
        #expect(WireBase64.decode("QUJD") == Data("ABC".utf8))
        #expect(WireBase64.decode("QUI=") == Data("AB".utf8))
        #expect(WireBase64.decode("QQ==") == Data("A".utf8))
        #expect(WireBase64.decode("") == nil)          // au moins 4 caractères
        #expect(WireBase64.decode("QUJ") == nil)       // longueur non multiple de 4
        #expect(WireBase64.decode("QU JD") == nil)     // espace
        #expect(WireBase64.decode("Q=JD") == nil)      // remplissage au milieu
        #expect(WireBase64.decode("Q===") == nil)      // trop de remplissage
        #expect(WireBase64.decode("QUJD\n") == nil)    // fin de ligne
        #expect(WireBase64.decode("QU-D") == nil)      // alphabet URL refusé
    }

    @Test func lectureDesFixtures() throws {
        let hello = try Fixtures.recorded("v3.15.1/handshake-sessions/001-result-zcode-agent.helloConversationV4.json")
        #expect(hello["protocolVersion"] == .number(3))
        let records = try Fixtures.records(in: "v3.15.1/send-text")
        #expect(records.count == 9)
        #expect(records.first?.name == "zcode-agent.helloConversationV4")
        #expect(records[3].kind == "event")
    }
}
