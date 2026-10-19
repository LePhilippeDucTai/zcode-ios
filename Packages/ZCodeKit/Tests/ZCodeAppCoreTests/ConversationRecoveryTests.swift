import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

@MainActor
struct ConversationRecoveryTests {
    @Test func envoiInconnuRenvoyeAvecLeMemeIdentifiant() async throws {
        let (first, second, queue) = try await cutAndResumeServers { _ in .string("unknown") }
        let model = makeConversation(queue)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        #expect(model.unconfirmedCount == 1)
        try await emitConversation(second, initialConversationFrame())          // reprise automatique
        _ = try await eventually { await second.calls(to: "zcode-agent.sendConversationCommandV4").count == 1 ? true : nil }
        let sent = try #require(await first.calls(to: "zcode-agent.sendConversationCommandV4").first?["envelope"]?["commandId"])
        let resent = try #require(await second.calls(to: "zcode-agent.sendConversationCommandV4").first?["envelope"]?["commandId"])
        #expect(resent == sent)
        let query = try #require(await second.calls(to: "zcode-agent.queryConversationCommandsV4").first)
        #expect(query["commands"] == .array([.object(["sessionId": .string(pongSession), "commandId": sent])]))
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }
    }

    @Test func envoiDejaRecuPasRenvoye() async throws {
        let (first, second, queue) = try await cutAndResumeServers { key in
            .object(["commandId": key["commandId"] ?? .null, "status": .string("accepted"), "revisionAtDecision": .number(9)])
        }
        let model = makeConversation(queue)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        try await emitConversation(second, initialConversationFrame())
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }
        #expect(await second.calls(to: "zcode-agent.sendConversationCommandV4").isEmpty)
        #expect(model.commandError == nil)
        #expect(model.returnedDraft == nil)                                      // accepté : rien à rendre
    }

    @Test func erreurDuServeurNEstPasUneCoupure() async throws {
        let server = try await conversationServer()
        await server.on("zcode-agent.sendConversationCommandV4") { _ in throw CheckError("refus interne") }
        let model = makeConversation(ServerQueue([server]))
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .failed)
        #expect(model.unconfirmedCount == 0)
        #expect(model.commandError != nil)
    }

    @Test func rapprochementUneFoisParAbonnement() async throws {
        let (first, second, queue) = try await cutAndResumeServers { _ in .null }
        await second.on("zcode-agent.queryConversationCommandsV4") { _ in throw CheckError("indisponible") }
        let model = makeConversation(queue)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        try await emitConversation(second, initialConversationFrame())
        for prefix in ["006", "007", "008"] {                                    // streaming : trames successives
            await second.emit(conversationEvent, try conversationRecord(prefix))
        }
        _ = try await eventually { (model.snapshot?.revision ?? 0) > 10 ? true : nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await second.calls(to: "zcode-agent.queryConversationCommandsV4").count == 1)   // pas un appel par trame
        #expect(model.unconfirmedCount == 1)                                     // gardé pour la reconnexion suivante
    }

    @Test func renvoiCoupeGardePourLaReprise() async throws {
        let (first, second, _) = try await cutAndResumeServers { _ in .string("unknown") }
        let secondTransport = second.transport
        await second.on("zcode-agent.sendConversationCommandV4") { _ in
            secondTransport.finish()                                                // le renvoi aussi est coupé
            return .null
        }
        let third = try await conversationServer()
        await third.on("zcode-agent.queryConversationCommandsV4") { argument in
            let key = argument["commands"]?.arrayValue?.first ?? .null
            return .object(["results": .array([.object(["key": key, "result": .string("unknown")])])])
        }
        let model = makeConversation(ServerQueue([first, second, third]))
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        try await emitConversation(second, initialConversationFrame())
        _ = try await eventually { await second.calls(to: "zcode-agent.sendConversationCommandV4").count == 1 ? true : nil }
        try await emitConversation(third, initialConversationFrame())               // reprise suivante
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }
        let sent = try #require(await first.calls(to: "zcode-agent.sendConversationCommandV4").first?["envelope"]?["commandId"])
        let resends = await second.calls(to: "zcode-agent.sendConversationCommandV4")
            + (await third.calls(to: "zcode-agent.sendConversationCommandV4"))
        #expect(resends.count == 2)                                                 // pas perdu : renvoyé à la reprise
        #expect(resends.allSatisfy { $0["envelope"]?["commandId"] == sent })       // toujours le même identifiant
        #expect(model.commandError == nil)
        #expect(model.returnedDraft == nil)
    }

    @Test func renvoiRefuseParLHoteEstOublieEtAffiche() async throws {
        let (first, second, queue) = try await cutAndResumeServers { _ in .string("unknown") }
        await second.on("zcode-agent.sendConversationCommandV4") { argument in
            .object(["commandId": argument["envelope"]?["commandId"] ?? .null, "status": .string("rejected"),
                     "reasonCode": .string("proto.invalidPayload")])
        }
        let model = makeConversation(queue)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        try await emitConversation(second, initialConversationFrame())
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }
        #expect(model.commandError != nil)
        #expect(model.returnedDraft == "bonjour")                                // le composeur avait vidé le brouillon
        #expect(model.takeReturnedDraft() == "bonjour")
        #expect(model.returnedDraft == nil)                                      // rendu une seule fois
    }

    @Test func envoiConnuRefuseRendLeTexte() async throws {
        let (first, second, queue) = try await cutAndResumeServers { key in
            .object(["commandId": key["commandId"] ?? .null, "status": .string("rejected"),
                     "reasonCode": .string("proto.invalidPayload")])
        }
        let model = makeConversation(queue)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        try await emitConversation(second, initialConversationFrame())
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }
        #expect(model.commandError != nil)
        #expect(model.takeReturnedDraft() == "bonjour")
    }

    @Test func renvoiEnErreurDeLHoteEstAbandonne() async throws {
        let (first, second, queue) = try await cutAndResumeServers { _ in .string("unknown") }
        await second.on("zcode-agent.sendConversationCommandV4") { _ in throw CheckError("refus interne") }
        let model = makeConversation(queue)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        try await emitConversation(second, initialConversationFrame())
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }   // la bannière se ferme
        #expect(model.commandError != nil)
        #expect(model.takeReturnedDraft() == "bonjour")
        await model.refresh()                                                    // reprise suivante : plus rien à renvoyer
        try await emitConversation(second, initialConversationFrame())
        try await Task.sleep(for: .milliseconds(100))
        #expect(await second.calls(to: "zcode-agent.sendConversationCommandV4").count == 1)
    }

    @Test func rapprochementEnErreurAbandonneApresTroisPassages() async throws {
        let (first, second, queue) = try await cutAndResumeServers { _ in .null }
        await second.on("zcode-agent.queryConversationCommandsV4") { _ in throw CheckError("indisponible") }
        let model = makeConversation(queue)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        for pass in 1...ConversationModel.maxReconcileFailures {
            if pass > 1 { await model.refresh() }
            try await emitConversation(second, initialConversationFrame())
            _ = try await eventually {
                await second.calls(to: "zcode-agent.queryConversationCommandsV4").count == pass ? true : nil
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.unconfirmedCount == (pass < ConversationModel.maxReconcileFailures ? 1 : 0))
        }
        #expect(model.commandError != nil)
        #expect(model.takeReturnedDraft() == "bonjour")
    }

    @Test func abandonRendLesPiecesJointes() async throws {
        let (first, second, queue) = try await cutAndResumeServers { _ in .null }
        await second.on("zcode-agent.queryConversationCommandsV4") { _ in throw CheckError("indisponible") }
        await acceptUploads(on: first)
        let model = makeConversation(queue)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        model.attach(data: Data([1]), fileName: "a.png", mime: "image/png")
        _ = try await eventually { model.attachments.first?.isReady == true ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        #expect(model.attachments.isEmpty)                                         // gardées pour le rapprochement
        for pass in 1...ConversationModel.maxReconcileFailures {
            if pass > 1 { await model.refresh() }
            try await emitConversation(second, initialConversationFrame())
            _ = try await eventually {
                await second.calls(to: "zcode-agent.queryConversationCommandsV4").count == pass ? true : nil
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.unconfirmedCount == (pass < ConversationModel.maxReconcileFailures ? 1 : 0))
        }
        #expect(model.commandError != nil)
        #expect(model.takeReturnedDraft() == "bonjour")
        #expect(model.attachments.map(\.fileName) == ["a.png"])
        #expect(model.attachments.first?.isReady == true)                         // référence gardée, renvoyable
    }

    /// Rendues à l'abandon alors que le composeur en porte déjà d'autres : plus de 8, l'envoi est refusé.
    @Test func abandonAuDelaDeHuitPiecesJointesRefuseLEnvoi() async throws {
        let (first, second, queue) = try await cutAndResumeServers { _ in .null }
        await second.on("zcode-agent.queryConversationCommandsV4") { _ in throw CheckError("indisponible") }
        await acceptUploads(on: first)
        await acceptUploads(on: second)
        let model = makeConversation(queue)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        for index in 0..<ConversationModel.maxAttachments {
            model.attach(data: Data([UInt8(index)]), fileName: "\(index).png", mime: "image/png")
        }
        _ = try await eventually { model.canSendAttachments ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        #expect(model.attachments.isEmpty)
        for pass in 1...ConversationModel.maxReconcileFailures {
            if pass > 1 { await model.refresh() }
            try await emitConversation(second, initialConversationFrame())
            _ = try await eventually {
                await second.calls(to: "zcode-agent.queryConversationCommandsV4").count == pass ? true : nil
            }
            if pass == 1 {                                                         // nouvelles pièces jointes pendant l'attente
                for index in 0..<ConversationModel.maxAttachments {
                    model.attach(data: Data([UInt8(100 + index)]), fileName: "n\(index).png", mime: "image/png")
                }
                _ = try await eventually { model.canSendAttachments ? true : nil }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.attachments.count == 2 * ConversationModel.maxAttachments)  // 8 rendues + 8 nouvelles
        #expect(await model.send("encore") == .failed)
        #expect(model.commandError == "8 pièces jointes au plus par message.")
        #expect(await second.calls(to: "zcode-agent.sendConversationCommandV4").isEmpty)
    }
}

/// Accusé de commande pour la clé interrogée (`status`, `reasonCode` facultatif).
func ack(_ key: JSONValue, status: String, reason: String? = nil) -> JSONValue {
    var ack: [String: JSONValue] = ["commandId": key["commandId"] ?? .null, "status": .string(status)]
    if let reason { ack["reasonCode"] = .string(reason) }
    return .object(ack)
}

/// Réponse de l'hôte illisible (`AgentV4Error`), connexion intacte : le serveur répond tout de suite, sans coupure.
@MainActor
struct ConversationGarbledReplyTests {
    let sendMethod = "zcode-agent.sendConversationCommandV4"
    let queryMethod = "zcode-agent.queryConversationCommandsV4"

    /// Serveur unique : l'envoi reçoit `sendReply` (illisible par défaut) et le rapprochement `queryResult`.
    func server(sendReply: @escaping @Sendable (JSONValue, Int) -> JSONValue = { _, _ in .string("illisible") },
                queryResult: @escaping @Sendable (JSONValue) -> JSONValue) async throws -> FakeZCodeServer {
        let server = try await conversationServer()
        let sends = Counter()
        await server.on(sendMethod) { argument in sendReply(argument, sends.next()) }
        await server.on(queryMethod) { argument in
            let keys = argument["commands"]?.arrayValue ?? []
            return .object(["results": .array(keys.map { .object(["key": $0, "result": queryResult($0)]) })])
        }
        return server
    }

    func ready(_ server: FakeZCodeServer, retryDelays: [Duration] = ConversationModel.defaultReconcileRetryDelays) async throws -> ConversationModel {
        let model = makeConversation(ServerQueue([server]), retryDelays: retryDelays)
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        return model
    }

    @Test func reponseIllisibleGardeEtRapprocheSansReconnexion() async throws {
        let server = try await server { ack($0, status: "accepted") }
        let queue = ServerQueue([server])
        let model = makeConversation(queue)
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        #expect(model.unconfirmedCount == 1)                                     // gardé, pas rendu
        #expect(model.returnedDraft == nil)
        _ = try await eventually { await server.calls(to: queryMethod).count == 1 ? true : nil }
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }    // accepté : oublié
        #expect(queue.opened == 1)                                               // aucune reconnexion
        #expect(await server.calls(to: sendMethod).count == 1)                   // pas renvoyé
        #expect(model.commandError == nil)
        #expect(model.returnedDraft == nil)
        let sent = try #require(await server.calls(to: sendMethod).first?["envelope"]?["commandId"])
        let query = try #require(await server.calls(to: queryMethod).first)
        #expect(query["commands"] == .array([.object(["sessionId": .string(pongSession), "commandId": sent])]))
    }

    @Test func reponseIllisibleInconnueRenvoyeeAvecLeMemeIdentifiant() async throws {
        let server = try await server(
            sendReply: { argument, call in call == 1 ? .string("illisible") : acceptedAck(argument) },
            queryResult: { _ in .string("unknown") })
        let model = try await ready(server)
        #expect(await model.send("bonjour") == .unconfirmed)
        #expect(model.unconfirmedCount == 1)
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }
        let sends = try #require(await server.calls(to: sendMethod).count == 2 ? await server.calls(to: sendMethod) : nil)
        #expect(sends[0]["envelope"]?["commandId"] == sends[1]["envelope"]?["commandId"])
        #expect(sends[0]["envelope"] == sends[1]["envelope"])                    // même enveloppe
        #expect(await server.calls(to: queryMethod).count == 1)
        #expect(model.commandError == nil)
        #expect(model.returnedDraft == nil)
    }

    @Test func goalIllisibleRefuseRendLaCommande() async throws {
        let server = try await server { ack($0, status: "rejected", reason: "proto.invalidPayload") }
        let model = try await ready(server)
        #expect(await model.send("/goal tests verts") == .unconfirmed)
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }
        #expect(model.takeReturnedDraft() == "/goal tests verts")                // texte saisi, pas l'objectif seul
    }

    @Test func reponseIllisibleRefuseeRendLeTexte() async throws {
        let server = try await server { ack($0, status: "rejected", reason: "proto.invalidPayload") }
        let model = try await ready(server)
        #expect(await model.send("bonjour") == .unconfirmed)
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }
        #expect(model.commandError != nil)
        #expect(model.takeReturnedDraft() == "bonjour")
        #expect(await server.calls(to: sendMethod).count == 1)
    }

    /// Illisible → passe → inconnu → renvoi illisible → nouvelle passe après le délai… : chaque passage coûte un essai
    /// à l'envoi, qui est abandonné au plafond, dans le même abonnement et sans boucle.
    @Test func reponseIllisibleAuRenvoiNeBouclePasEtFinitParAbandonner() async throws {
        let server = try await server(queryResult: { _ in .string("unknown") })
        let model = try await ready(server, retryDelays: [.milliseconds(10)])
        #expect(await model.send("bonjour") == .unconfirmed)
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }
        try await Task.sleep(for: .milliseconds(150))                            // une passe de trop se verrait ici
        let max = ConversationModel.maxReconcileFailures
        #expect(await server.calls(to: queryMethod).count == max)
        #expect(await server.calls(to: sendMethod).count == max + 1)             // l'envoi puis un renvoi par passe
        let ids = Set(await server.calls(to: sendMethod).compactMap { $0["envelope"]?["commandId"] })
        #expect(ids.count == 1)                                                  // toujours le même identifiant
        #expect(await server.calls(to: "zcode-agent.subscribeConversationV4").count == 1)
        #expect(model.takeReturnedDraft() == "bonjour")
        #expect(model.commandError?.contains("vérifie") == true)
    }

    /// Cas (a) : une reprise a déjà rapproché dans cet abonnement, puis un envoi est illisible.
    @Test func envoiIllisibleApresUneReprisePendantLeMemeAbonnement() async throws {
        let (first, second, queue) = try await cutAndResumeServers { _ in .string("unknown") }
        let queries = Counter()
        await second.on(queryMethod) { argument in
            let key = argument["commands"]?.arrayValue?.first ?? .null
            let result = queries.next() == 1 ? JSONValue.string("unknown") : ack(key, status: "accepted")
            return .object(["results": .array([.object(["key": key, "result": result])])])
        }
        let sends = Counter()
        await second.on(sendMethod) { argument in sends.next() == 1 ? acceptedAck(argument) : .string("illisible") }
        let model = makeConversation(queue)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("un") == .unconfirmed)                          // coupé
        try await emitConversation(second, initialConversationFrame())            // reprise : passe 1, renvoi accepté
        _ = try await eventually {
            let resent = await second.calls(to: sendMethod).count            // lecture seule : ne touche pas au compteur du faux serveur
            return model.unconfirmedCount == 0 && resent == 1 ? true : nil
        }
        #expect(await second.calls(to: queryMethod).count == 1)
        #expect(await model.send("deux") == .unconfirmed)                        // illisible, même abonnement
        #expect(model.unconfirmedCount == 1)
        _ = try await eventually { await second.calls(to: queryMethod).count == 2 ? true : nil }
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }
        #expect(await second.calls(to: "zcode-agent.subscribeConversationV4").count == 1)
        #expect(model.returnedDraft == nil)
        #expect(model.commandError == nil)
    }

    /// Cas (b) et (c) : deux envois illisibles de suite (le second peut tomber pendant le passage du premier) sont tous
    /// deux réglés, sans nouvel abonnement.
    @Test func deuxEnvoisIllisiblesDeSuiteSontTousReglees() async throws {
        let server = try await server { ack($0, status: "accepted") }
        let model = try await ready(server)
        #expect(await model.send("un") == .unconfirmed)
        #expect(await model.send("deux") == .unconfirmed)
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.calls(to: sendMethod).count == 2)                   // ni perdus ni renvoyés
        #expect(await server.calls(to: "zcode-agent.subscribeConversationV4").count == 1)
        #expect(model.returnedDraft == nil)
        #expect(model.commandError == nil)
    }
}

/// `queryUnavailable` et catalogue.
@MainActor
struct ConversationRecoveryCapTests {
    let sendMethod = "zcode-agent.sendConversationCommandV4"
    let queryMethod = "zcode-agent.queryConversationCommandsV4"

    @Test func rapprochementIndisponibleAbandonneAuPlafond() async throws {
        let (first, second, queue) = try await cutAndResumeServers { key in
            .object(["commandId": key["commandId"] ?? .null, "status": .string("failed"),
                     "reasonCode": .string("fault.command.queryUnavailable")])
        }
        let model = makeConversation(queue)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        for pass in 1...ConversationModel.maxReconcileFailures {
            if pass > 1 { await model.refresh() }
            try await emitConversation(second, initialConversationFrame())
            _ = try await eventually { await second.calls(to: queryMethod).count == pass ? true : nil }
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.unconfirmedCount == (pass < ConversationModel.maxReconcileFailures ? 1 : 0))
        }
        #expect(model.takeReturnedDraft() == "bonjour")
        #expect(model.commandError?.contains("vérifie") == true)
        #expect(await second.calls(to: sendMethod).isEmpty)                       // jamais renvoyé : l'hôte ne sait pas
    }

    /// Hôte qui répond toujours `queryUnavailable`, connexion saine : abandon au plafond dans le même abonnement.
    @Test func rapprochementIndisponibleAbandonneSansReconnexion() async throws {
        let server = try await conversationServer()
        await server.on(sendMethod) { _ in .string("illisible") }
        await server.on(queryMethod) { argument in
            let keys = argument["commands"]?.arrayValue ?? []
            return .object(["results": .array(keys.map { key in
                .object(["key": key, "result": .object([
                    "commandId": key["commandId"] ?? .null, "status": .string("failed"),
                    "reasonCode": .string("fault.command.queryUnavailable"),
                ])])
            })])
        }
        let model = makeConversation(ServerQueue([server]), retryDelays: [.milliseconds(10)])
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await server.calls(to: queryMethod).count == ConversationModel.maxReconcileFailures)   // borné
        #expect(await server.calls(to: sendMethod).count == 1)                   // jamais renvoyé : l'hôte ne sait pas
        #expect(await server.calls(to: "zcode-agent.subscribeConversationV4").count == 1)
        #expect(model.takeReturnedDraft() == "bonjour")
        #expect(model.commandError?.contains("vérifie") == true)
    }

    /// Serveur unique : tout envoi est illisible ; le rapprochement répond `queryResult` pour chaque clé (rien du tout
    /// si `queryResult` rend `nil` : l'enveloppe est absente de la réponse).
    func garbledSendServer(queryResult: @escaping @Sendable (JSONValue) -> JSONValue?) async throws -> FakeZCodeServer {
        let server = try await conversationServer()
        await server.on(sendMethod) { _ in .string("illisible") }
        await server.on(queryMethod) { argument in
            let keys = argument["commands"]?.arrayValue ?? []
            return .object(["results": .array(keys.compactMap { key in
                queryResult(key).map { .object(["key": key, "result": $0]) }
            })])
        }
        return server
    }

    /// Plusieurs envois illisibles rapprochés : le budget d'un envoi se consomme à raison d'un essai par délai écoulé,
    /// pas à chaque nouvel envoi (trois envois à 100 ms d'écart ne doivent pas abandonner le premier).
    @Test func envoisIllisiblesRapprochesNeConsommentPasLeBudgetDesAutres() async throws {
        let server = try await garbledSendServer { ack($0, status: "failed", reason: "fault.command.queryUnavailable") }
        let model = makeConversation(ServerQueue([server]), retryDelays: [.seconds(5)])
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        for text in ["un", "deux", "trois"] {
            #expect(await model.send(text) == .unconfirmed)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.unconfirmedCount == 3)                                     // aucun abandonné avant le délai
        #expect(model.returnedDraft == nil)
        #expect(model.commandError == nil)
        #expect(await server.calls(to: sendMethod).count == 3)                   // jamais renvoyés : l'hôte ne sait pas
    }

    /// Un envoi illisible pendant le chargement (avant le premier snapshot) est rapproché dès que la conversation est prête.
    @Test func envoiIllisiblePendantLeChargementRapprocheAuPremierSnapshot() async throws {
        let server = try await garbledSendServer { ack($0, status: "failed", reason: "fault.command.queryUnavailable") }
        let model = makeConversation(ServerQueue([server]), retryDelays: [.seconds(5)])
        await model.start()
        #expect(model.phase == .loading)                                         // pas encore de snapshot
        #expect(await model.send("bonjour") == .unconfirmed)
        _ = try await eventually { await server.calls(to: queryMethod).count == 1 ? true : nil }
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.phase == .loading)
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        _ = try await eventually { await server.calls(to: queryMethod).count == 2 ? true : nil }   // pas bloqué
        #expect(model.unconfirmedCount == 1)
    }

    /// Écart assumé avec ZCode §9.3 : le délai avant la requête suivante croît avec les essais perdus (ici 60 ms puis
    /// 250 ms), au lieu d'un intervalle fixe.
    @Test func lesDelaisDeRelanceCroissent() async throws {
        let instants = Recorder<ContinuousClock.Instant>()
        let server = try await garbledSendServer { key in
            instants.append(.now)
            return ack(key, status: "failed", reason: "fault.command.queryUnavailable")
        }
        let model = makeConversation(ServerQueue([server]), retryDelays: [.milliseconds(60), .milliseconds(250)])
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }       // abandonné à la troisième requête
        let times = instants.all
        try #require(times.count == ConversationModel.maxReconcileFailures)
        #expect(times[1] - times[0] >= .milliseconds(60))
        #expect(times[2] - times[1] >= .milliseconds(250))                          // plus long que le premier
    }

    /// `stop()` pendant le délai d'attente : plus aucune requête, l'envoi reste gardé pour la reprise.
    @Test func arretPendantLeDelaiNeRelancePlusLaRequete() async throws {
        let server = try await garbledSendServer { ack($0, status: "failed", reason: "fault.command.queryUnavailable") }
        let model = makeConversation(ServerQueue([server]), retryDelays: [.milliseconds(150)])
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        _ = try await eventually { await server.calls(to: queryMethod).count == 1 ? true : nil }
        await model.stop()                                                       // pendant le délai
        try await Task.sleep(for: .milliseconds(400))
        #expect(await server.calls(to: queryMethod).count == 1)
        #expect(model.unconfirmedCount == 1)
        #expect(model.returnedDraft == nil)
    }

    /// Enveloppe absente de la réponse : chaque passage coûte un essai, sans renvoi, puis le texte est rendu.
    @Test func enveloppeAbsenteDeLaReponseAbandonneApresTroisRequetes() async throws {
        let server = try await garbledSendServer { _ in nil }
        let model = makeConversation(ServerQueue([server]), retryDelays: [.milliseconds(10)])
        await model.start()
        try await emitConversation(server, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        _ = try await eventually { model.unconfirmedCount == 0 ? true : nil }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await server.calls(to: queryMethod).count == ConversationModel.maxReconcileFailures)
        #expect(await server.calls(to: sendMethod).count == 1)                   // jamais renvoyé
        #expect(model.takeReturnedDraft() == "bonjour")
        #expect(model.commandError?.contains("vérifie") == true)
    }

    /// Une réponse définitive remet le compte à zéro : l'indisponibilité n'est comptée que si elle se répète.
    @Test func rapprochementIndisponibleRemisAZeroParUneReponse() async throws {
        let calls = Counter()
        let unavailableCalls = ConversationModel.maxReconcileFailures - 1
        let (first, second, queue) = try await cutAndResumeServers { key in
            if calls.next() <= unavailableCalls {
                return .object(["commandId": key["commandId"] ?? .null, "status": .string("failed"),
                                "reasonCode": .string("fault.command.queryUnavailable")])
            }
            return .object(["commandId": key["commandId"] ?? .null, "status": .string("accepted")])
        }
        let model = makeConversation(queue)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready ? true : nil }
        #expect(await model.send("bonjour") == .unconfirmed)
        for pass in 1...ConversationModel.maxReconcileFailures {
            if pass > 1 { await model.refresh() }
            try await emitConversation(second, initialConversationFrame())
            _ = try await eventually { await second.calls(to: queryMethod).count == pass ? true : nil }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.unconfirmedCount == 0)
        #expect(model.returnedDraft == nil)                                       // accepté à la dernière passe
        #expect(model.commandError == nil)
    }

    /// Serveur de conversation qui sert aussi le catalogue des modèles.
    func catalogConversationServer() async throws -> FakeZCodeServer {
        let server = try await catalogServer(revisions: { let r = Recorder<Int>(); r.append(4); return r }())
        let ack = try conversationRecord("003")
        await server.on("zcode-agent.subscribeConversationV4") { _ in ack }
        await server.on("zcode-agent.unsubscribeConversationV4") { _ in .null }
        return server
    }

    @Test func catalogueDemarreUneFoisParReprise() async throws {
        let first = try await catalogConversationServer()
        let second = try await catalogConversationServer()
        let servers = ServerQueue([first, second])
        let connection = HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(servers: servers))
        let catalog = ModelCatalog(connection: connection)
        let model = ConversationModel(connection: connection, builder: CommandBuilder(clientId: "client-test"),
                                      workspace: testWorkspacePath, sessionId: pongSession, catalog: catalog)
        await model.start()
        try await emitConversation(first, initialConversationFrame())
        _ = try await eventually { model.phase == .ready && catalog.view != nil ? true : nil }
        _ = try await eventually { await first.listenerCount("model-selection.onDidChange") == 1 ? true : nil }
        #expect(await first.calls(to: "model-selection.getView").count == 1)
        first.transport.finish()                                                  // Mac en veille
        try await emitConversation(second, initialConversationFrame())
        _ = try await eventually { model.phase == .ready && servers.opened == 2 ? true : nil }
        _ = try await eventually { await second.calls(to: "model-selection.getView").count >= 1 ? true : nil }
        try await Task.sleep(for: .milliseconds(200))                             // un second démarrage se verrait ici
        #expect(await second.calls(to: "model-selection.getView").count == 1)
        #expect(await second.listenerCount("model-selection.onDidChange") == 1)
    }
}

struct CheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
