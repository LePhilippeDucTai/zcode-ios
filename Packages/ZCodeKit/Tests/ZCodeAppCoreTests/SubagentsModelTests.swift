import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Agent synthétique au format de `subagents.list`.
private func agentJSON(
    _ name: String, scope: String, source: String, description: String = "d", projectPath: String? = nil,
    pluginId: String? = nil, pluginName: String? = nil, readOnly: Bool = false, enabled: Bool = true,
    tools: [String]? = nil
) -> JSONValue {
    let id: String
    let path: String
    switch source {
    case "built-in":
        id = "built-in:built-in:\(name.lowercased())"
        path = "built-in:\(name)"
    case "plugin":
        id = "plugin:\(pluginId ?? "p@m"):\(name)"
        path = "/h/plugins/\(name).md"
    default:
        id = "user:\(scope):\(name)"
        path = "\(projectPath ?? "/h")/\(name).md"
    }
    var object: [String: JSONValue] = [
        "id": .string(id), "name": .string(name), "path": .string(path), "description": .string(description),
        "systemPrompt": .string("s"), "scope": .string(scope), "source": .string(source),
        "readOnly": .bool(readOnly), "enabled": .bool(enabled),
    ]
    if let projectPath { object["projectPath"] = .string(projectPath) }
    if let pluginId { object["pluginId"] = .string(pluginId) }
    if let pluginName { object["pluginName"] = .string(pluginName) }
    if let tools { object["tools"] = .array(tools.map(JSONValue.string)) }
    return .object(object)
}

private let pluginIdentifier = "documents@zcode-plugins-official"

/// Un agent utilisateur, un agent de projet `/w`, un agent de projet `/autre`, un agent de plugin et les deux intégrés.
private func mixedListJSON() -> JSONValue {
    let alpha = agentJSON("alpha", scope: "user", source: "user", description: "Révue du code")
    let projectW = agentJSON("proj-w", scope: "workspace", source: "user", projectPath: "/w")
    let projectOther = agentJSON("proj-autre", scope: "workspace", source: "user", projectPath: "/autre")
    let plugin = agentJSON("documents:visual-judge", scope: "user", source: "plugin", pluginId: pluginIdentifier,
                           pluginName: "documents", readOnly: true)
    let general = agentJSON("general-purpose", scope: "built-in", source: "built-in", readOnly: true, tools: ["*"])
    let explore = agentJSON("Explore", scope: "built-in", source: "built-in", readOnly: true, tools: ["Read", "Grep"])
    return .object([
        "agents": .array([general, explore, alpha, projectW, projectOther, plugin]),
        "userAgents": .array([alpha, projectW, projectOther]),
        "pluginAgents": .array([plugin]),
        "capability": .object(["userScopeAvailable": .bool(true)]),
    ])
}

private func mixedList() throws -> AgentsListResult {
    try AgentsListResult(json: mixedListJSON())
}

private func agent(named name: String, in list: AgentsListResult) throws -> AgentSummary {
    try #require((list.agents + list.userAgents + list.pluginAgents).first { $0.name == name })
}

@MainActor
private func makeModel(
    _ server: FakeZCodeServer, scope: ExtensionScope = .user, workspaces: [String] = [testWorkspacePath]
) -> SubagentsModel {
    let connection = HostConnection(
        host: testHost, endpoint: testEndpoint,
        dependencies: makeDependencies(servers: ServerQueue([server]), serverInfo: { makeServerInfo(workspaces: workspaces) }))
    return SubagentsModel(connection: connection, scope: scope)
}

private func listServer(_ list: JSONValue = mixedListJSON()) async throws -> FakeZCodeServer {
    let server = try await readyServer()
    await server.on("subagents.list") { _ in list }
    await server.on("subagents.setEnabled") { _ in .null }
    await server.on("subagents.deleteAgent") { _ in .null }
    await server.on("subagents.setBuiltInModelOverride") { _ in .null }
    return server
}

private func remote(_ message: String, name: String = "Error", code: JSONValue? = nil) -> RPCError {
    var object: [String: JSONValue] = ["message": .string(message), "name": .string(name)]
    if let code { object["code"] = code }
    return .remote(RemoteError(RPCValue(.object(object))))
}

@MainActor
struct SubagentsModelTests {
    @Test func sectionsParPortee() async throws {
        let server = try await listServer()
        let user = makeModel(server)
        await user.loadIfNeeded()
        let sections = user.sections(query: "")
        #expect(sections.map(\.kind) == [.custom, .plugin(id: pluginIdentifier, name: "documents"), .builtIn])
        #expect(sections.map(\.agents.count) == [1, 1, 2])
        #expect(sections[2].agents.map(\.name) == ["Explore", "general-purpose"])

        let project = makeModel(try await listServer(), scope: .workspace("/w"))   // un serveur par connexion
        await project.loadIfNeeded()
        let projectSections = project.sections(query: "")
        #expect(projectSections.map(\.kind) == [.custom])
        #expect(projectSections[0].agents.map(\.name) == ["proj-w"])
    }

    @Test func requeteDeListeSelonLaPortee() async throws {
        let server = try await listServer()
        await makeModel(server).loadIfNeeded()
        #expect(await server.calls(to: "subagents.list") == [.object([
            "workspacePath": .string(testWorkspacePath), "provider": .string("glm"), "mode": .string("settingsUserOnly"),
        ])])
    }

    @Test func requeteDeListeEnPorteeProjet() async throws {
        let server = try await listServer()
        await makeModel(server, scope: .workspace("/w")).loadIfNeeded()
        #expect(await server.calls(to: "subagents.list") == [.object([
            "workspacePath": .string("/w"), "provider": .string("glm"), "mode": .string("allRuntimeScopes"),
        ])])
    }

    @Test func projetDeLaPorteeSuffitSansProjetAnnonce() async throws {
        let server = try await listServer()
        let model = makeModel(server, scope: .workspace("/w"), workspaces: [])
        await model.loadIfNeeded()
        #expect(model.phase == .ready)
    }

    @Test func agentsEnLectureSeule() async throws {
        let server = try await listServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        let list = try #require(model.list)
        await model.delete(try agent(named: "Explore", in: list))
        #expect(model.actionError == "Ce sous-agent est en lecture seule (intégré ou fourni par un plugin).")
        model.dismissMessages()
        #expect(model.actionError == nil)
        await model.setEnabled(try agent(named: "documents:visual-judge", in: list), false)
        #expect(model.actionError == "Ce sous-agent est en lecture seule (intégré ou fourni par un plugin).")
        #expect(await server.calls(to: "subagents.deleteAgent").isEmpty)
        #expect(await server.calls(to: "subagents.setEnabled").isEmpty)
        #expect(model.notice == nil)
    }

    @Test func activationRelitLaListe() async throws {
        let server = try await listServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        let alpha = try agent(named: "alpha", in: try #require(model.list))
        await model.setEnabled(alpha, false)
        #expect(await server.calls(to: "subagents.setEnabled") == [.object([
            "agentId": .string("user:user:alpha"), "enabled": .bool(false),
        ])])
        #expect(await server.calls(to: "subagents.list").count == 2)
        #expect(model.notice == ExtensionsLabels.subagentsTakeEffect)
        #expect(model.actionError == nil)
        #expect(!model.busy)
    }

    @Test func suppressionRelitLaListe() async throws {
        let server = try await listServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        let alpha = try agent(named: "alpha", in: try #require(model.list))
        await model.delete(alpha)
        #expect(await server.calls(to: "subagents.deleteAgent") == [.object([
            "agentId": .string("user:user:alpha"), "filePath": .string("/h/alpha.md"),
        ])])
        #expect(await server.calls(to: "subagents.list").count == 2)
        #expect(model.notice == ExtensionsLabels.subagentsTakeEffect)
    }

    @Test func suppressionRefuseeParLHoteRelitQuandMeme() async throws {
        let server = try await listServer()
        await server.on("subagents.deleteAgent") { _ in throw FakeRemoteError("Subagents service is disposed") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.delete(try agent(named: "alpha", in: try #require(model.list)))
        #expect(model.actionError == "Le service des sous-agents est arrêté sur l'hôte : redémarre ZCode.")
        #expect(await server.calls(to: "subagents.list").count == 2)
        #expect(model.notice == nil)
    }

    @Test func modeleDUnIntegre() async throws {
        let server = try await listServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        let explore = try agent(named: "Explore", in: try #require(model.list))
        let selection = ModelSelection(providerId: "prov", modelId: "mod", reasoningLevel: "high")
        await model.setModelOverride(explore, selection)
        #expect(await server.calls(to: "subagents.setBuiltInModelOverride") == [
            .object(["agentName": .string("Explore"), "modelSelection": try V4JSON.encode(selection)]),
        ])
        #expect(await server.calls(to: "subagents.list").count == 2)
        #expect(model.notice == ExtensionsLabels.subagentsTakeEffect)
    }

    @Test func memeNomDansDeuxProjetsCibleLeBonFichier() async throws {
        // `user:workspace:<nom>` ne porte pas le projet : seul le chemin distingue les deux fichiers.
        let inW = agentJSON("commun", scope: "workspace", source: "user", projectPath: "/w")
        let inOther = agentJSON("commun", scope: "workspace", source: "user", projectPath: "/autre")
        let list = JSONValue.object([
            "agents": .array([]), "userAgents": .array([inW, inOther]), "pluginAgents": .array([]),
        ])
        let server = try await listServer(list)
        let model = makeModel(server, scope: .workspace("/autre"))
        await model.loadIfNeeded()
        let result = try #require(model.list)
        let other = try #require(result.userAgents.first { $0.projectPath == "/autre" })
        let mine = try #require(result.userAgents.first { $0.projectPath == "/w" })
        #expect(other.id == mine.id && other.path != mine.path)
        #expect(model.agent(id: other.id, path: other.path)?.projectPath == "/autre")
        #expect(model.agent(id: mine.id, path: mine.path)?.projectPath == "/w")
        #expect(model.agent(id: other.id, path: "/inconnu.md") == nil)
        await model.delete(other)
        #expect(await server.calls(to: "subagents.deleteAgent") == [.object([
            "agentId": .string(other.id), "filePath": .string(other.path),
        ])])
    }

    @Test func avisGardeAuRetourEffaceParActualisation() async throws {
        let server = try await listServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        let list = try #require(model.list)
        await model.setEnabled(try agent(named: "alpha", in: list), false)
        #expect(model.notice != nil)
        await model.loadIfNeeded()                                           // retour du détail : l'avis reste visible
        #expect(model.notice == ExtensionsLabels.subagentsTakeEffect)
        await model.delete(try agent(named: "Explore", in: list))            // refus du client
        #expect(model.actionError != nil)
        await model.refresh()                                                // actualisation explicite : tout s'efface
        #expect(model.actionError == nil)
        #expect(model.notice == nil)
    }

    @Test func hoteInjoignable() async throws {
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: ServerQueue([])))
        let model = SubagentsModel(connection: connection, scope: .user)
        await model.loadIfNeeded()
        guard case .failed(let message) = model.phase else { Issue.record("échec attendu"); return }
        #expect(message.hasPrefix("Sous-agents indisponibles : "))
        #expect(model.isReadOnly)
        #expect(model.list == nil)
    }

    @Test func hoteSansProjetAnnonce() async throws {
        let server = try await listServer()
        let model = makeModel(server, workspaces: [])
        await model.loadIfNeeded()
        #expect(model.phase == .failed("Sous-agents indisponibles : l'hôte n'annonce aucun projet."))
        #expect(await server.calls(to: "subagents.list").isEmpty)
    }

    @Test func listeGardeeHorsLigne() async throws {
        let server = try await readyServer()
        let calls = Counter()
        let list = mixedListJSON()
        await server.on("subagents.list") { _ in
            if calls.next() == 1 { return list }
            throw FakeRemoteError("panne")
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        #expect(model.phase == .ready)
        #expect(!model.isReadOnly)
        let first = try #require(model.list)
        await model.refresh()
        #expect(model.phase == .failed("Sous-agents indisponibles : panne"))
        #expect(model.list == first)
        #expect(model.isReadOnly)
        #expect(!model.isOffline)                                            // refus de l'hôte : pas une panne de connexion
        // Hors ligne, aucune action n'est tentée.
        await model.delete(try agent(named: "alpha", in: first))
        #expect(await server.calls(to: "subagents.deleteAgent").isEmpty)
    }

    @Test func nouvelEssaiApresUnEchec() async throws {
        let server = try await readyServer()
        let calls = Counter()
        let list = mixedListJSON()
        await server.on("subagents.list") { _ in
            if calls.next() == 1 { throw FakeRemoteError("panne") }
            return list
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        guard case .failed = model.phase else { Issue.record("échec attendu"); return }
        await model.loadIfNeeded()
        #expect(model.phase == .ready)
        await model.loadIfNeeded()                                           // déjà lue : relue en silence
        #expect(await server.calls(to: "subagents.list").count == 3)
    }

    @Test func rechercheSansAccents() async throws {
        let server = try await listServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        let found = model.sections(query: "revue")
        #expect(found.map(\.kind) == [.custom])
        #expect(found[0].agents.map(\.name) == ["alpha"])
        #expect(model.sections(query: "EXPLORE").map(\.kind) == [.builtIn])
        #expect(model.sections(query: "introuvable").isEmpty)
    }

    @Test func libellesDErreur() {
        let table: [(String, String)] = [
            ("Name must be between 3 and 50 characters", "Le nom doit compter de 3 à 50 caractères."),
            ("Name can only contain letters, numbers, and hyphens",
             "Le nom ne peut contenir que des lettres, des chiffres et des tirets."),
            ("Description is required", "La description est obligatoire."),
            ("System prompt is required", "Les instructions sont obligatoires."),
            ("Agent name \"explore\" is reserved by a built-in agent", "Ce nom est réservé à un sous-agent intégré."),
            ("Agent file \"abc.md\" already exists", "Un sous-agent de ce nom existe déjà dans cette portée."),
            ("Workspace path is required for workspace subagents", "Projet manquant pour un sous-agent de projet."),
            ("Subagents service is disposed", "Le service des sous-agents est arrêté sur l'hôte : redémarre ZCode."),
            ("Method not found: list", "Cette version de ZCode ne gère pas les sous-agents."),
            ("Unknown channel", "Cette version de ZCode n'expose pas les sous-agents."),
            ("quelque chose d'autre", "quelque chose d'autre"),
            ("", "Erreur du serveur ZCode."),
        ]
        for (received, shown) in table {
            #expect(ExtensionsLabels.subagentFailure(remote(received)) == shown, "\(received)")
        }
        #expect(ExtensionsLabels.subagentFailure(remote("x", code: .number(-32601)))
            == "Cette version de ZCode ne gère pas les sous-agents.")
        #expect(ExtensionsLabels.subagentFailure(SubagentsClientError.readOnly("a"))
            == "Ce sous-agent est en lecture seule (intégré ou fourni par un plugin).")
        #expect(ExtensionsLabels.subagentFailure(SubagentsClientError.notOverridable("a"))
            == "Le modèle de ce sous-agent se règle dans son formulaire.")
        #expect(ExtensionsLabels.subagentFailure(RPCError.connectionClosed)
            == ConnectionFailure(RPCError.connectionClosed).message)
        // Un message brut de l'hôte qui cite une adresse est masqué.
        #expect(ExtensionsLabels.subagentFailure(remote("échec de https://u:t@h/a?token=x"))
            == "échec de https://•••@h/a?token=•••")
    }
}

/// Relectures à la réapparition de la liste : un plugin installé ailleurs apporte des sous-agents, ZCode Web peut en
/// modifier ; une liste déjà lue se relit donc en silence.
@MainActor
struct SubagentsModelRefreshTests {
    @Test func agentApporteParUnPluginVuAuRetour() async throws {
        let plugin = agentJSON("documents:visual-judge", scope: "user", source: "plugin", pluginId: pluginIdentifier,
                               pluginName: "documents", readOnly: true)
        let before: JSONValue = .object(["agents": .array([]), "userAgents": .array([]), "pluginAgents": .array([])])
        let after: JSONValue = .object(["agents": .array([plugin]), "userAgents": .array([]), "pluginAgents": .array([plugin])])
        let server = try await readyServer()
        let installed = Flag()
        await server.on("subagents.list") { _ in installed.isSet ? after : before }
        let model = makeModel(server)
        await model.loadIfNeeded()
        #expect(model.sections(query: "").isEmpty)
        installed.set()                                                      // plugin installé depuis l'écran Plugins
        await model.loadIfNeeded()
        #expect(model.sections(query: "").flatMap(\.agents).map(\.name) == ["documents:visual-judge"])
        #expect(model.phase == .ready)
    }

    @Test func relectureSilencieuseSansChargementVisible() async throws {
        let server = try await listServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.setEnabled(try agent(named: "alpha", in: try #require(model.list)), false)
        let list = model.list
        await server.onDeferred("subagents.list")
        let reload = Task { await model.loadIfNeeded() }
        _ = try await eventually { await server.calls(to: "subagents.list").count == 3 ? true : nil }
        #expect(model.phase == .ready)
        #expect(!model.isReadOnly)
        #expect(model.list == list)
        #expect(model.notice == ExtensionsLabels.subagentsTakeEffect)
        await server.respondDeferred("subagents.list", mixedListJSON())
        await reload.value
        #expect(model.notice == ExtensionsLabels.subagentsTakeEffect)
        #expect(model.phase == .ready)
    }

    @Test func relectureSilencieuseNonAnnuleeParLaDisparitionDeLEcran() async throws {
        let server = try await listServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        await server.onDeferred("subagents.list")
        let reload = Task { await model.loadIfNeeded() }
        _ = try await eventually { await server.calls(to: "subagents.list").count == 2 ? true : nil }
        reload.cancel()
        await server.respondDeferred("subagents.list", mixedListJSON())
        await reload.value
        #expect(model.phase == .ready)
    }

    @Test func aucuneRelecturePendantUneAction() async throws {
        let server = try await listServer()
        await server.onDeferred("subagents.deleteAgent")
        let model = makeModel(server)
        await model.loadIfNeeded()
        let alpha = try agent(named: "alpha", in: try #require(model.list))
        let deletion = Task { await model.delete(alpha) }
        _ = try await eventually { await server.calls(to: "subagents.deleteAgent").isEmpty ? nil : true }
        await model.loadIfNeeded()
        #expect(await server.calls(to: "subagents.list").count == 1)
        await server.respondDeferred("subagents.deleteAgent", .null)
        await deletion.value
        #expect(await server.calls(to: "subagents.list").count == 2)
    }

    @Test func horsLigneSeulementPourUnePanneDeConnexion() async throws {
        let server = try await listServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        server.transport.finish()
        await model.refresh()
        guard case .failed = model.phase else { Issue.record("échec attendu"); return }
        #expect(model.isOffline)
        #expect(model.list != nil)
        let unreachable = SubagentsModel(
            connection: HostConnection(host: testHost, endpoint: testEndpoint, dependencies: makeDependencies(servers: ServerQueue([]))),
            scope: .user)
        await unreachable.loadIfNeeded()
        #expect(unreachable.isOffline)
    }

    /// `capability.userScopeAvailable == false` (hôte web sans portée Utilisateur, motif `desktop_only`) : en portée
    /// Utilisateur, état « non pris en charge » et création refusée ; en portée Projet, rien ne change.
    @Test func porteeUtilisateurIndisponible() async throws {
        let list: JSONValue = .object([
            "agents": .array([]), "userAgents": .array([]), "pluginAgents": .array([]),
            "capability": .object(["userScopeAvailable": .bool(false), "userScopeReason": .string("desktop_only")]),
        ])
        let user = makeModel(try await listServer(list))
        await user.loadIfNeeded()
        #expect(user.userScopeUnavailable == ExtensionsLabels.userScopeUnavailable(reason: "desktop_only"))
        #expect(!user.canCreate)
        var form = SubagentForm(scope: .user)
        form.name = "revue-code"
        form.description = "d"
        form.systemPrompt = "s"
        #expect(await !user.save(form, editing: nil))
        #expect(user.actionError == ExtensionsLabels.userScopeUnavailable(reason: "desktop_only"))
        let project = makeModel(try await listServer(list), scope: .workspace("/w"))
        await project.loadIfNeeded()
        #expect(project.userScopeUnavailable == nil)
        #expect(project.canCreate)
        let available = makeModel(try await listServer())
        await available.loadIfNeeded()
        #expect(available.userScopeUnavailable == nil)
        #expect(available.canCreate)
    }
}

struct SubagentSectionsTests {
    @Test func pluginsGroupesParIdentifiantEtTries() throws {
        let one = agentJSON("b:two", scope: "user", source: "plugin", pluginId: "zeta@m", pluginName: "zeta", readOnly: true)
        let two = agentJSON("a:one", scope: "user", source: "plugin", pluginId: "alpha@m", readOnly: true)
        let three = agentJSON("b:three", scope: "user", source: "plugin", pluginId: "zeta@m", pluginName: "zeta", readOnly: true)
        let list = try AgentsListResult(json: .object([
            "agents": .array([]), "userAgents": .array([]), "pluginAgents": .array([one, two, three]),
        ]))
        let sections = SubagentSections.make(list, scope: .user, query: "")
        // Titre : `pluginName`, à défaut l'identifiant.
        #expect(sections.map(\.title) == ["alpha@m", "zeta"])
        #expect(sections[1].agents.map(\.name) == ["b:three", "b:two"])
        #expect(Set(sections.map(\.id)).count == 2)
    }

    @Test func pluginDeProjetSeulementDansSonProjet() throws {
        let inside = agentJSON("p:in", scope: "workspace", source: "plugin", projectPath: "/w", pluginId: "x@m", readOnly: true)
        let outside = agentJSON("p:out", scope: "workspace", source: "plugin", projectPath: "/autre", pluginId: "x@m", readOnly: true)
        let userLevel = agentJSON("p:user", scope: "user", source: "plugin", pluginId: "x@m", readOnly: true)
        let list = try AgentsListResult(json: .object([
            "agents": .array([]), "userAgents": .array([]), "pluginAgents": .array([inside, outside, userLevel]),
        ]))
        let project = SubagentSections.make(list, scope: .workspace("/w"), query: "")
        #expect(project.flatMap(\.agents).map(\.name) == ["p:in"])
        let user = SubagentSections.make(list, scope: .user, query: "")
        #expect(user.flatMap(\.agents).map(\.name) == ["p:user"])
    }
}

struct ExtensionsLabelsTests {
    @Test func porteeUtilisateurIndisponibleLibelles() {
        #expect(ExtensionsLabels.userScopeUnavailable(reason: "desktop_only")
            == "Sous-agents de l'utilisateur non pris en charge par cet hôte : réservés à l'application de bureau ZCode.")
        #expect(ExtensionsLabels.userScopeUnavailable(reason: nil)
            == "Sous-agents de l'utilisateur non pris en charge par cet hôte.")
        #expect(ExtensionsLabels.userScopeUnavailable(reason: "autre https://u:t@h/")
            == "Sous-agents de l'utilisateur non pris en charge par cet hôte (autre https://•••@h/).")
    }

    @Test func bandeauDeLectureSeule() {
        #expect(ExtensionsLabels.readOnlyBanner(offline: true) == "Hors ligne : liste en lecture seule")
        #expect(ExtensionsLabels.readOnlyBanner(offline: false) == "Lecture impossible : liste en lecture seule")
    }

    @Test func portees() {
        #expect(ExtensionsLabels.scope(.user) == "Utilisateur")
        #expect(ExtensionsLabels.scope(.workspace("/Users/p/claude")) == "Projet claude")
        #expect(ExtensionsLabels.target(hostName: "Mac", scope: .workspace("/Users/p/claude")) == "Mac · Projet claude")
        #expect(ExtensionsLabels.target(hostName: "Mac", scope: .user) == "Mac · Utilisateur")
    }

    @Test func couleurs() {
        let expected = ["yellow": "jaune", "red": "rouge", "orange": "orange", "green": "vert", "cyan": "cyan",
                        "blue": "bleu", "purple": "violet", "pink": "rose"]
        for (raw, label) in expected { #expect(ExtensionsLabels.color(AgentColor(rawValue: raw)) == label) }
        #expect(ExtensionsLabels.color(AgentColor(rawValue: "magenta")) == "magenta")
    }

    @Test func outils() {
        #expect(ExtensionsLabels.tools(nil) == "Tous les outils")
        #expect(ExtensionsLabels.tools([]) == "Tous les outils")
        #expect(ExtensionsLabels.tools(["Read", "*"]) == "Tous les outils")
        #expect(ExtensionsLabels.tools(["Read"]) == "1 outil")
        #expect(ExtensionsLabels.tools(["Read", "Grep"]) == "2 outils")
    }

    @Test func modele() throws {
        let view = try ModelSelectionView(json: try Fixtures.recorded("v3.15.1/handshake-sessions/005-result-model-selection.getView.json"))
        let provider = try #require(view.providers.first)
        let model = try #require(provider.visibleModels.first)
        let level = try #require(model.reasoningLevels.last)
        let selection = ModelSelection(providerId: provider.providerId, modelId: model.modelId, reasoningLevel: level)
        #expect(ExtensionsLabels.model(nil, catalog: view, inherit: "Modèle de la session") == "Modèle de la session")
        #expect(ExtensionsLabels.model(selection, catalog: view, inherit: "x") == "\(model.modelId) · \(ChatLabels.effort(level))")
        let unknown = ModelSelection(providerId: "p", modelId: "inconnu", reasoningLevel: "high")
        #expect(ExtensionsLabels.model(unknown, catalog: view, inherit: "x") == "inconnu")
        #expect(ExtensionsLabels.model(unknown, catalog: nil, inherit: "x") == "inconnu")
    }

    @Test func provenance() throws {
        let list = try mixedList()
        #expect(ExtensionsLabels.provenance(try agent(named: "Explore", in: list)) == "Intégré")
        #expect(ExtensionsLabels.provenance(try agent(named: "documents:visual-judge", in: list)) == "Plugin documents")
        #expect(ExtensionsLabels.provenance(try agent(named: "alpha", in: list)) == "Personnalisé")
    }
}

struct ModelChoiceTests {
    private func view() throws -> ModelSelectionView {
        try ModelSelectionView(json: .object([
            "revision": .number(1),
            "providers": .array([.object([
                "providerId": .string("p"), "providerName": .string("P"),
                "models": .array([
                    .object(["modelId": .string("fort"), "config": .object([
                        "enabled": .bool(true),
                        "optionSpecs": .object(["reasoningLevel": .object(["values": .array([.string("low"), .string("high")])])]),
                    ])]),
                    .object(["modelId": .string("simple")]),
                    .object(["modelId": .string("coupe"), "config": .object(["enabled": .bool(false)])]),
                ]),
            ])]),
        ]))
    }

    @Test func choixDUnModeleAvecSonEffortLePlusFort() throws {
        let view = try view()
        let strong = try #require(view.model(providerId: "p", modelId: "fort"))
        let selection = ModelChoice.selecting(providerId: "p", model: strong)
        #expect(selection == ModelSelection(providerId: "p", modelId: "fort", reasoningLevel: "high"))
        let simple = try #require(view.model(providerId: "p", modelId: "simple"))
        #expect(ModelChoice.selecting(providerId: "p", model: simple).options == nil)
    }

    @Test func disponibiliteEtEffort() throws {
        let view = try view()
        let high = ModelSelection(providerId: "p", modelId: "fort", reasoningLevel: "high")
        #expect(ModelChoice.isAvailable(high, in: view))
        #expect(!ModelChoice.isAvailable(ModelSelection(providerId: "p", modelId: "coupe"), in: view))
        #expect(!ModelChoice.isAvailable(ModelSelection(providerId: "p", modelId: "absent"), in: view))
        #expect(!ModelChoice.isAvailable(ModelSelection(providerId: "q", modelId: "fort"), in: view))
        #expect(ModelChoice.supportsEffort(high, in: view))
        #expect(ModelChoice.supportsEffort(ModelSelection(providerId: "p", modelId: "fort"), in: view))
        #expect(!ModelChoice.supportsEffort(ModelSelection(providerId: "p", modelId: "fort", reasoningLevel: "max"), in: view))
        #expect(!ModelChoice.supportsEffort(ModelSelection(providerId: "p", modelId: "simple", reasoningLevel: "high"), in: view))
    }
}

// MARK: - Création et modification

private let projectPath = "/Users/me/claude/.zcode-check/extensions"

private func lifecycle(_ prefix: String) throws -> JSONValue {
    try Fixtures.record(in: "v3.15.1/subagents-lifecycle", prefix: prefix)
}

/// Une liste puis une autre, selon le nombre de lectures déjà faites.
private func sequencedServer(_ lists: [JSONValue]) async throws -> FakeZCodeServer {
    let server = try await readyServer()
    let calls = Counter()
    await server.on("subagents.list") { _ in lists[min(calls.next(), lists.count) - 1] }
    return server
}

@MainActor
struct SubagentsModelEditionTests {
    @Test func creationDansLeProjetPuisRelecture() async throws {
        let server = try await listServer()
        await server.on("subagents.createAgent") { _ in try lifecycle("008") }
        let model = makeModel(server, scope: .workspace("/w"))
        await model.loadIfNeeded()
        var form = SubagentForm(scope: .workspace("/w"))
        form.name = " revue-code "
        form.description = "Relit le code"
        form.systemPrompt = "Relis."
        form.allTools = false
        form.selectedTools = ["Grep", "Read"]
        #expect(await model.save(form, editing: nil))
        #expect(await server.calls(to: "subagents.createAgent") == [.object([
            "config": .object([
                "name": .string("revue-code"), "description": .string("Relit le code"), "systemPrompt": .string("Relis."),
                "color": .string("yellow"), "injectAgentsMd": .bool(true),
                "tools": .array([.string("Read"), .string("Grep")]),
            ]),
            "provider": .string("glm"), "scope": .string("workspace"), "workspacePath": .string("/w"),
        ])])
        #expect(await server.calls(to: "subagents.list").count == 2)
        #expect(model.notice == ExtensionsLabels.subagentsTakeEffect)
        #expect(model.actionError == nil)
        #expect(!model.busy)
    }

    @Test func creationEnPorteeUtilisateur() async throws {
        let server = try await listServer()
        await server.on("subagents.createAgent") { _ in try lifecycle("008") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        var form = SubagentForm(scope: .user)
        form.name = "revue-code"
        form.description = "d"
        form.systemPrompt = "s"
        #expect(await model.save(form, editing: nil))
        let calls = await server.calls(to: "subagents.createAgent")
        #expect(calls.first?["scope"] == .string("user"))
        #expect(calls.first?["workspacePath"] == nil)
    }

    @Test func renommageEnvoieLAncienChemin() async throws {
        let server = try await listServer()
        let renamed = agentJSON("alpha-2", scope: "user", source: "user")
        await server.on("subagents.updateAgent") { _ in .object(["agent": renamed]) }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let alpha = try agent(named: "alpha", in: try #require(model.list))
        var form = SubagentForm(editing: alpha, scope: .user)
        form.name = "alpha-2"
        #expect(await model.save(form, editing: alpha))
        let calls = await server.calls(to: "subagents.updateAgent")
        #expect(calls == [.object([
            "agentId": .string("user:user:alpha"), "oldFilePath": .string(alpha.path),
            "config": form.config(basedOn: alpha).json, "provider": .string("glm"), "scope": .string("user"),
        ])])
        #expect(calls.first?["config"]?["name"] == .string("alpha-2"))
        #expect(await server.calls(to: "subagents.list").count == 2)
        #expect(model.notice == ExtensionsLabels.subagentsTakeEffect)
    }

    @Test func modificationEnvoieLaPorteeDeLAgent() async throws {
        let server = try await listServer()
        await server.on("subagents.updateAgent") { _ in .object(["agent": agentJSON("proj-w", scope: "workspace", source: "user", projectPath: "/w")]) }
        let model = makeModel(server, scope: .workspace("/w"))
        await model.loadIfNeeded()
        let project = try #require(model.customAgents.first)
        #expect(project.name == "proj-w")
        #expect(await model.save(SubagentForm(editing: project, scope: .workspace("/w")), editing: project))
        let call = try #require(await server.calls(to: "subagents.updateAgent").first)
        #expect(call["scope"] == .string("workspace") && call["workspacePath"] == .string("/w"))
    }

    @Test func modificationRefuseeSiLAgentNEstPasModifiable() async throws {
        let server = try await listServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        let explore = try agent(named: "Explore", in: try #require(model.list))
        var form = SubagentForm(editing: explore, scope: .user)
        form.name = "autre-nom"
        #expect(await !model.save(form, editing: explore))
        #expect(model.actionError == ExtensionsLabels.subagentReadOnly)
        #expect(await server.calls(to: "subagents.updateAgent").isEmpty)
    }

    @Test func formulaireInvalideSansAppel() async throws {
        let server = try await listServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        var form = SubagentForm(scope: .user)
        form.name = "ab"
        #expect(await !model.save(form, editing: nil))
        #expect(model.actionError == ExtensionsLabels.nameLength)
        #expect(await server.calls(to: "subagents.createAgent").isEmpty)
        #expect(await server.calls(to: "subagents.list").count == 1)
        #expect(model.notice == nil)
        // Nom déjà pris dans la portée : refusé avant tout appel.
        var taken = SubagentForm(scope: .user)
        taken.name = "ALPHA"
        taken.description = "d"
        taken.systemPrompt = "s"
        #expect(await !model.save(taken, editing: nil))
        #expect(model.actionError == ExtensionsLabels.nameTaken)
        #expect(await server.calls(to: "subagents.createAgent").isEmpty)
    }

    @Test func nomPrisSurLHote() async throws {
        let server = try await listServer()
        await server.on("subagents.createAgent") { _ in throw FakeRemoteError("Agent file \"zcode.md\" already exists") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        var form = SubagentForm(scope: .user)
        form.name = "zcode"
        form.description = "d"
        form.systemPrompt = "s"
        #expect(await !model.save(form, editing: nil))
        #expect(model.actionError == "Un sous-agent de ce nom existe déjà dans cette portée.")
        #expect(model.notice == nil)
        #expect(await server.calls(to: "subagents.list").count == 2)         // relue quand même
    }

    @Test func enregistrementHorsLigneRefuse() async throws {
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: ServerQueue([])))
        let model = SubagentsModel(connection: connection, scope: .user)
        await model.loadIfNeeded()
        var form = SubagentForm(scope: .user)
        form.name = "revue-code"
        form.description = "d"
        form.systemPrompt = "s"
        #expect(await !model.save(form, editing: nil))
        #expect(model.customAgents.isEmpty)
    }

    @Test func agentsModifiablesDeLaPortee() async throws {
        let user = makeModel(try await listServer())
        await user.loadIfNeeded()
        #expect(user.customAgents.map(\.name) == ["alpha"])
        let project = makeModel(try await listServer(), scope: .workspace("/w"))
        await project.loadIfNeeded()
        #expect(project.customAgents.map(\.name) == ["proj-w"])
    }

    @Test func leDetailSuitLeRenommage() async throws {
        // Cycle réel : liste avant, réponse de `updateAgent`, liste après.
        let before = try lifecycle("005")
        let after = try lifecycle("007")
        let server = try await sequencedServer([before, after])
        await server.on("subagents.updateAgent") { _ in try lifecycle("006") }
        let model = makeModel(server, scope: .workspace(projectPath))
        await model.loadIfNeeded()
        let old = try #require(model.customAgents.first)
        #expect(old.name == "zcode-ios-probe-agent")

        var form = SubagentForm(editing: old, scope: .workspace(projectPath))
        form.name = "zcode-ios-probe-agent-v2"
        form.description = #"Description avec "guillemets" et \ barre"#
        #expect(await model.save(form, editing: old))

        // La description part déséchappée ; l'hôte l'échappe et la renvoie échappée : la liste affiche ce qu'il renvoie.
        let sent = try #require(await server.calls(to: "subagents.updateAgent").first)
        #expect(sent["config"]?["description"] == .string(#"Description avec "guillemets" et \ barre"#))
        #expect(sent["oldFilePath"] == .string(old.path))
        #expect(sent["scope"] == .string("workspace") && sent["workspacePath"] == .string(projectPath))

        #expect(model.agent(id: old.id, path: old.path)?.name == "zcode-ios-probe-agent-v2")
        let renamed = try #require(model.customAgents.first)
        #expect(model.agent(id: old.id, path: old.path) == renamed)
        // Re-modifier l'agent suivi ne fait pas grossir la description : relue puis déséchappée = envoyée.
        #expect(SubagentForm(editing: renamed, scope: .workspace(projectPath)).description == form.description)
    }

    @Test func successeurAbsentDeLaListeGardeLAncien() async throws {
        let server = try await listServer()
        let renamed = agentJSON("alpha-2", scope: "user", source: "user")
        await server.on("subagents.updateAgent") { _ in .object(["agent": renamed]) }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let alpha = try agent(named: "alpha", in: try #require(model.list))
        var form = SubagentForm(editing: alpha, scope: .user)
        form.name = "alpha-2"
        #expect(await model.save(form, editing: alpha))
        // Le nouvel agent n'est pas dans la liste relue (réponse figée du faux hôte) : aucun agent inventé, l'ancien reste.
        #expect(model.agent(id: "user:user:alpha-2", path: "/h/alpha-2.md") == nil)
        #expect(model.agent(id: alpha.id, path: alpha.path)?.name == "alpha")
    }

    @Test func avisConserveAuRetourDeLaListe() async throws {
        let server = try await listServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        let explore = try agent(named: "Explore", in: try #require(model.list))
        await model.setModelOverride(explore, ModelSelection(providerId: "p", modelId: "m", reasoningLevel: "high"))
        #expect(model.notice == ExtensionsLabels.subagentsTakeEffect)
        await model.loadIfNeeded()                                           // `.task` de la liste au retour du détail
        #expect(model.notice == ExtensionsLabels.subagentsTakeEffect)
        #expect(await server.calls(to: "subagents.list").count == 3)         // relue en silence, avis gardé
        await model.refresh()
        #expect(model.notice == nil)
    }

    @Test func nouvelAgentDeMemeNomApresRenommage() async throws {
        // A renommé en B, puis un nouvel A est créé : A et B existent ; chercher A trouve le nouvel A, jamais B.
        let alphaJSON = agentJSON("alpha", scope: "user", source: "user")
        let betaJSON = agentJSON("alpha-2", scope: "user", source: "user")
        func listWith(_ agents: [JSONValue]) -> JSONValue {
            .object(["agents": .array(agents), "userAgents": .array(agents), "pluginAgents": .array([])])
        }
        let server = try await sequencedServer([listWith([alphaJSON]), listWith([betaJSON]), listWith([alphaJSON, betaJSON])])
        await server.on("subagents.updateAgent") { _ in .object(["agent": betaJSON]) }
        await server.on("subagents.createAgent") { _ in .object(["agent": alphaJSON]) }
        await server.on("subagents.deleteAgent") { _ in .null }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let old = try #require(model.customAgents.first)
        var rename = SubagentForm(editing: old, scope: .user)
        rename.name = "alpha-2"
        #expect(await model.save(rename, editing: old))
        #expect(model.agent(id: old.id, path: old.path)?.name == "alpha-2")     // le détail suit le renommage

        var again = SubagentForm(scope: .user)
        again.name = "alpha"
        again.description = "d"
        again.systemPrompt = "s"
        #expect(await model.save(again, editing: nil))
        let recreated = try #require(model.agent(id: old.id, path: old.path))
        #expect(recreated.name == "alpha" && recreated.path == old.path)         // plus de renommage fantôme
        await model.delete(recreated)
        #expect(await server.calls(to: "subagents.deleteAgent") == [.object([
            "agentId": .string(old.id), "filePath": .string(old.path),
        ])])
    }
}
