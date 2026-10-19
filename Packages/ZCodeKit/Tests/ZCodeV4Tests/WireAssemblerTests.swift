import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Construit des fragments à partir d'octets logiques (cas d'erreur ; la référence positive vient du TS).
func makeFragments(
    _ logical: Data,
    cutAt cuts: [Int],
    ordinal: Int = 1,
    id: String = "lf-1",
    delivery: String = "online",
    topic: String = "conversation/s1",
    subscriptionId: String = "sub-1",
    checksum: String? = nil
) -> [JSONValue] {
    let bounds = [0] + cuts + [logical.count]
    let parts = zip(bounds, bounds.dropFirst()).map { logical.subdata(in: $0..<$1) }
    return parts.enumerated().map { index, part in
        .object([
            "wireVersion": .number(3), "kind": .string("fragment"), "deliveryKind": .string(delivery),
            "logicalFrameId": .string(id), "logicalFrameOrdinal": .number(Double(ordinal)),
            "topic": .string(topic), "subscriptionId": .string(subscriptionId),
            "fragmentIndex": .number(Double(index)), "fragmentCount": .number(Double(parts.count)),
            "logicalBytes": .number(Double(logical.count)),
            "checksum": .object(["algorithm": .string("crc32"), "value": .string(checksum ?? CRC32.hex(logical))]),
            "dataBase64": .string(part.base64EncodedString()),
        ])
    }
}

/// Trame logique minimale pour la route par défaut de `makeFragments`.
func logicalFrame(text: String = "Bonjour", topic: String = "conversation/s1", subscriptionId: String = "sub-1") -> Data {
    Data(#"{"topic":"\#(topic)","subscriptionId":"\#(subscriptionId)","fromSeq":1,"toSeq":2,"sentAt":1,"payload":{"kind":"deltas","deltas":[{"op":"row.delta","rowId":1,"path":"text","append":"\#(text)"}]}}"#.utf8)
}

func faults(_ events: [AssemblyEvent]) -> [String] {
    events.compactMap { if case .fault(let fault) = $0 { fault.reasonCode } else { nil } }
}

func completes(_ events: [AssemblyEvent]) -> [LogicalFrame] {
    events.compactMap { if case .complete(let frame) = $0 { frame } else { nil } }
}

struct WireAssemblerTests {
    let t0 = ContinuousClock.now

    @Test func vecteurTypeScriptReassembleDansLeDesordre() throws {
        let wires = try #require(Fixtures.file("synthetic/fragments-v3.json").arrayValue)
        var assembler = WireAssembler()
        #expect(assembler.accept(wires[2], now: t0).isEmpty)
        #expect(assembler.accept(wires[0], now: t0).isEmpty)
        #expect(assembler.stagedBytes > 0)
        let events = assembler.accept(wires[1], now: t0)
        let frame = try #require(completes(events).first)
        #expect(frame.route == WireRoute(topic: "conversation/sess_frag", subscriptionId: "sub-frag-1"))
        #expect(frame.deliveryKind == .recovery)
        #expect(frame.ordinal == 9)
        #expect(frame.frame["toSeq"] == .number(3))
        #expect(frame.frame["payload"]?["deltas"]?.arrayValue?.first?["append"] == .string("Réponse découpée 🌍 en fragments."))
        #expect(assembler.stagedBytes == 0)
        #expect(assembler.activeAssemblyCount == 0)
    }

    @Test func trameCompleteReelleTransmise() throws {
        let wire = try Fixtures.recorded("v3.15.1/send-text/006-event-zcode-agent.onDynamicConversationFrame.json")
        var assembler = WireAssembler()
        let frame = try #require(completes(assembler.accept(wire, now: t0)).first)
        #expect(frame.deliveryKind == .online)
        #expect(frame.ordinal == 2)
        #expect(frame.frame == wire["frame"])
    }

    @Test func fragmentIdentiqueEnDoubleAccepte() throws {
        let wires = makeFragments(logicalFrame(), cutAt: [40, 90])
        var assembler = WireAssembler()
        #expect(assembler.accept(wires[0], now: t0).isEmpty)
        #expect(assembler.accept(wires[0], now: t0).isEmpty)
        #expect(assembler.accept(wires[1], now: t0).isEmpty)
        #expect(completes(assembler.accept(wires[2], now: t0)).count == 1)
    }

    @Test func fragmentContradictoireRejete() {
        let good = makeFragments(logicalFrame(text: "AAAA"), cutAt: [40, 90])
        let other = makeFragments(logicalFrame(text: "BBBB"), cutAt: [40, 90], checksum: CRC32.hex(logicalFrame(text: "AAAA")))
        var assembler = WireAssembler()
        _ = assembler.accept(good[2], now: t0)
        #expect(faults(assembler.accept(other[2], now: t0)) == ["proto.frameAssemblyFragmentConflict"])
        #expect(assembler.stagedBytes == 0)
    }

    @Test func sommeDeControleFausseRejetee() {
        let wires = makeFragments(logicalFrame(), cutAt: [50], checksum: "00000000")
        var assembler = WireAssembler()
        _ = assembler.accept(wires[0], now: t0)
        #expect(faults(assembler.accept(wires[1], now: t0)) == ["proto.frameAssemblyChecksumMismatch"])
    }

    @Test func coupureAuMilieuDUnCaractereUTF8() throws {
        let logical = logicalFrame(text: "é🌍é")
        let accent = try #require(logical.firstIndex(of: 0xC3))      // premier octet de « é »
        let wires = makeFragments(logical, cutAt: [accent + 1])       // coupe entre 0xC3 et 0xA9
        var assembler = WireAssembler()
        _ = assembler.accept(wires[0], now: t0)
        let frame = try #require(completes(assembler.accept(wires[1], now: t0)).first)
        #expect(frame.frame["payload"]?["deltas"]?.arrayValue?.first?["append"] == .string("é🌍é"))
    }

    @Test func metadonneesIncoherentesRejetees() {
        var wire = makeFragments(logicalFrame(), cutAt: [50])[0].objectValue!
        wire["fragmentCount"] = .number(10_000)                      // > logicalBytes
        var assembler = WireAssembler()
        #expect(faults(assembler.accept(.object(wire), now: t0)) == ["proto.frameFragmentCountExceeded"])
        wire = makeFragments(logicalFrame(), cutAt: [50], ordinal: 2)[0].objectValue!
        wire["fragmentIndex"] = .number(5)                           // ≥ fragmentCount
        #expect(faults(assembler.accept(.object(wire), now: t0)) == ["proto.frameAssemblyMetadataMismatch"])
        wire = makeFragments(logicalFrame(), cutAt: [50], ordinal: 3)[0].objectValue!
        wire["dataBase64"] = .string("pas du base64!")
        #expect(faults(assembler.accept(.object(wire), now: t0)) == ["proto.frameAssemblyInvalidBase64"])
        wire = makeFragments(logicalFrame(), cutAt: [50], ordinal: 4)[0].objectValue!
        wire["deliveryKind"] = .string("teleport")
        #expect(faults(assembler.accept(.object(wire), now: t0)) == ["proto.frameAssemblyMetadataMismatch"])
    }

    @Test func versionDeTrameInconnueSignalee() {
        var wire = makeFragments(logicalFrame(), cutAt: [50])[0].objectValue!
        wire["wireVersion"] = .number(4)
        var assembler = WireAssembler()
        #expect(faults(assembler.accept(.object(wire), now: t0)) == ["proto.wireVersionUnsupported"])
    }

    @Test func enveloppeNonRoutableIgnoree() {
        var assembler = WireAssembler()
        #expect(assembler.accept(.string("bruit"), now: t0).isEmpty)
        #expect(assembler.accept(.object(["kind": .string("complete")]), now: t0).isEmpty)
    }

    @Test func ordinalsDejaTraitesEtConflits() {
        var assembler = WireAssembler()
        let nine = makeFragments(logicalFrame(), cutAt: [50], ordinal: 9, id: "lf-9")
        _ = assembler.accept(nine[0], now: t0)
        #expect(completes(assembler.accept(nine[1], now: t0)).count == 1)
        // Rejeu tardif d'une trame plus ancienne ou identique : ignoré en silence.
        #expect(assembler.accept(makeFragments(logicalFrame(), cutAt: [50], ordinal: 8, id: "lf-8")[0], now: t0).isEmpty)
        #expect(assembler.accept(nine[0], now: t0).isEmpty)
        // Même ordinal, autre identifiant : conflit de protocole.
        let conflict = makeFragments(logicalFrame(), cutAt: [50], ordinal: 9, id: "lf-autre")
        #expect(faults(assembler.accept(conflict[0], now: t0)) == ["proto.frameAssemblyOrdinalConflict"])
    }

    @Test func assemblageRemplaceParUneTramePlusRecente() throws {
        var assembler = WireAssembler()
        let three = makeFragments(logicalFrame(), cutAt: [50], ordinal: 3, id: "lf-3")
        _ = assembler.accept(three[0], now: t0)
        let wire = try Fixtures.recorded("v3.15.1/send-text/006-event-zcode-agent.onDynamicConversationFrame.json")
        var complete = wire.objectValue!
        complete["topic"] = .string("conversation/s1")
        complete["subscriptionId"] = .string("sub-1")
        complete["logicalFrameOrdinal"] = .number(4)
        var frame = complete["frame"]!.objectValue!
        frame["topic"] = .string("conversation/s1")
        frame["subscriptionId"] = .string("sub-1")
        complete["frame"] = .object(frame)
        let events = assembler.accept(.object(complete), now: t0)
        #expect(faults(events) == ["proto.frameAssemblySuperseded"])
        #expect(completes(events).map(\.ordinal) == [4])
        #expect(assembler.stagedBytes == 0)
    }

    @Test func assemblageExpire() {
        var assembler = WireAssembler()
        let wires = makeFragments(logicalFrame(), cutAt: [50])
        _ = assembler.accept(wires[0], now: t0)
        #expect(assembler.nextDeadline == t0.advanced(by: .seconds(30)))
        #expect(assembler.expire(now: t0.advanced(by: .seconds(29))).isEmpty)
        #expect(faults(assembler.expire(now: t0.advanced(by: .seconds(30)))) == ["proto.frameAssemblyTimedOut"])
        #expect(assembler.nextDeadline == nil)
        #expect(assembler.stagedBytes == 0)
        // Le fragment manquant arrive trop tard : ignoré (pierre tombale).
        #expect(assembler.accept(wires[1], now: t0.advanced(by: .seconds(31))).isEmpty)
    }

    @Test func budgetDeMemoireRespecte() {
        var limits = WireLimits.protocolDefaults
        limits.maxStagedBytes = 60
        var assembler = WireAssembler(limits: limits)
        let first = makeFragments(logicalFrame(), cutAt: [50], ordinal: 1, id: "a", subscriptionId: "sub-1")
        let second = makeFragments(logicalFrame(subscriptionId: "sub-2"), cutAt: [50], ordinal: 1, id: "b", subscriptionId: "sub-2")
        _ = assembler.accept(first[0], now: t0)
        #expect(faults(assembler.accept(second[0], now: t0)) == ["proto.frameAssemblyBudgetExceeded"])
    }

    @Test func oublierUneRoute() {
        var assembler = WireAssembler()
        let wires = makeFragments(logicalFrame(), cutAt: [50])
        _ = assembler.accept(wires[0], now: t0)
        assembler.discard(WireRoute(topic: "conversation/s1", subscriptionId: "sub-1"))
        #expect(assembler.activeAssemblyCount == 0)
        #expect(assembler.stagedBytes == 0)
        // Après oubli, la même trame peut être reçue de nouveau en entier.
        _ = assembler.accept(wires[0], now: t0)
        #expect(completes(assembler.accept(wires[1], now: t0)).count == 1)
    }
}
