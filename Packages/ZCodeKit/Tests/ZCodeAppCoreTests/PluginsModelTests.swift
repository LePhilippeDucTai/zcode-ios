import Foundation
import Testing
import ZCodeAppCore
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

private func read(_ prefix: String) throws -> JSONValue {
    try Fixtures.record(in: "v3.15.1/plugins-read", prefix: prefix)
}

private let startDate = Date(timeIntervalSince1970: 1_791_890_000)

@MainActor
private func makeModel(
    _ server: FakeZCodeServer, scope: ExtensionScope = .user, workspaces: [String] = [testWorkspacePath]
) -> PluginsModel {
    makeModel(ServerQueue([server]), scope: scope, workspaces: workspaces)
}

/// Identifiant d'opération toujours `op-1` et horloge figée : les requêtes et l'état de l'opération sont exacts.
@MainActor
private func makeModel(
    _ servers: ServerQueue, scope: ExtensionScope = .user, workspaces: [String] = [testWorkspacePath]
) -> PluginsModel {
    let connection = HostConnection(
        host: testHost, endpoint: testEndpoint,
        dependencies: makeDependencies(servers: servers, serverInfo: { makeServerInfo(workspaces: workspaces) }))
    return PluginsModel(connection: connection, scope: scope, now: { startDate }, makeOperationId: { "op-1" })
}

private func lifecycle(_ prefix: String) throws -> JSONValue {
    try Fixtures.record(in: "v3.15.1/plugins-lifecycle", prefix: prefix)
}

private let probe = AvailablePlugin(id: "zcode-ios-probe@zcode-ios-probe-market", name: "zcode-ios-probe",
                                    marketplace: "zcode-ios-probe-market")
private let installedProbe = InstalledPlugin(id: "p@m", name: "p", marketplace: "m")

/// Détail de `installedProbe` : une option sensible, un libellé et un nombre.
private let configurable = PluginInfo(
    id: "p@m", name: "p", marketplace: "m", source: "cache",
    userConfig: [
        PluginConfigOption(key: "codeFactice", sensitive: true), PluginConfigOption(key: "label"),
        PluginConfigOption(key: "timeout", type: "number"),
    ], optionSources: ["codeFactice": "user"])

/// `configurable`, option sensible définie par le projet : effaçable en portée Projet.
private let configuredInProject = PluginInfo(
    id: "p@m", name: "p", marketplace: "m", source: "cache",
    userConfig: configurable.userConfig, optionSources: ["codeFactice": "workspace"])

private func errorDiagnostics(_ code: String, _ message: String) -> JSONValue {
    .object(["installedPlugins": .array([]), "dependencyClosure": .array([]), "diagnostics": .array([
        .object(["code": .string(code), "message": .string(message), "severity": .string("error")]),
    ])])
}

private func pluginsServer() async throws -> FakeZCodeServer {
    let server = try await readyServer()
    await server.on("plugin-management.getPluginsOverview") { _ in try read("001") }
    await server.on("plugin-management.listPlugins") { _ in try read("003") }
    await server.on("plugin-management.describePlugin") { _ in try read("004") }
    return server
}

/// Réponse de `addPluginMarketplace` : le résumé fictif pour `dryRun`, la source ajoutée sinon.
private func addHandler() -> FakeZCodeServer.Handler {
    { argument in
        if argument["dryRun"]?.boolValue == true { return try lifecycle("001") }
        return try lifecycle("002")
    }
}

private func marketplaceError(_ code: String, _ message: String) -> JSONValue {
    .object(["diagnostics": .array([
        .object(["code": .string(code), "message": .string(message), "severity": .string("error")]),
    ])])
}

private func remote(_ message: String, name: String = "Error", code: JSONValue? = nil) -> RPCError {
    var object: [String: JSONValue] = ["message": .string(message), "name": .string(name)]
    if let code { object["code"] = code }
    return .remote(RemoteError(RPCValue(.object(object))))
}

@MainActor
struct PluginsModelTests {
    @Test func lectureDeLApercu() async throws {
        let server = try await pluginsServer()
        let model = makeModel(server)
        #expect(model.phase == .idle)
        #expect(model.isReadOnly)
        await model.loadIfNeeded()
        #expect(model.phase == .ready)
        #expect(!model.isReadOnly)
        #expect(model.overview?.installedPlugins.map(\.id) == ["github@zcode-plugins-official"])
        #expect(model.details["visualize@zcode-plugins-official"]?.name == "visualize")
        #expect(model.details.count == 16)
        #expect(model.layout(query: "", category: nil).catalog.map(\.id) == ["zcode-plugins-official"])
        await model.loadIfNeeded()                                           // déjà lue : relue en silence
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)
        #expect(model.phase == .ready)
    }

    @Test func requetesDeLecture() async throws {
        let server = try await pluginsServer()
        await makeModel(server).loadIfNeeded()
        let user: JSONValue = .object(["workspacePath": .string(testWorkspacePath), "configScope": .string("user")])
        #expect(await server.calls(to: "plugin-management.getPluginsOverview") == [user])
        #expect(await server.calls(to: "plugin-management.listPlugins") == [user])

        let project = try await pluginsServer()
        await makeModel(project, scope: .workspace("/w")).loadIfNeeded()
        let workspace: JSONValue = .object(["workspacePath": .string("/w"), "configScope": .string("workspace")])
        #expect(await project.calls(to: "plugin-management.getPluginsOverview") == [workspace])
        #expect(await project.calls(to: "plugin-management.listPlugins") == [workspace])
    }

    @Test func projetDeLaPorteeSuffitSansProjetAnnonce() async throws {
        let server = try await pluginsServer()
        let model = makeModel(server, scope: .workspace("/w"), workspaces: [])
        await model.loadIfNeeded()
        #expect(model.phase == .ready)
    }

    @Test func hoteSansProjetAnnonce() async throws {
        let server = try await pluginsServer()
        let model = makeModel(server, workspaces: [])
        await model.loadIfNeeded()
        #expect(model.phase == .failed("Plugins indisponibles : l'hôte n'annonce aucun projet."))
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").isEmpty)
    }

    @Test func descriptionEnCache() async throws {
        let server = try await pluginsServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        let plugin = try #require(model.overview?.availablePlugins.first { $0.id == "cloudbase-skills@zcode-plugins-official" })
        await model.describe(plugin)
        await model.describe(plugin)
        let calls = await server.calls(to: "plugin-management.describePlugin")
        #expect(calls == [.object([
            "workspacePath": .string(testWorkspacePath), "marketplace": .string("zcode-plugins-official"),
            "pluginName": .string("cloudbase-skills"),
        ])])
        #expect(model.descriptions[plugin.id]?.components.isEmpty == false)
        #expect(model.actionError == nil)
    }

    @Test func descriptionEnEchec() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.describePlugin") { _ in throw FakeRemoteError("Plugin not found: x") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let plugin = try #require(model.overview?.availablePlugins.first)
        await model.describe(plugin)
        #expect(model.actionError == "Plugin introuvable sur l'hôte.")
        #expect(model.descriptions[plugin.id] == nil)
        model.dismissMessages()
        #expect(model.actionError == nil)
        // Un échec n'est pas gardé : l'ouverture suivante réessaie.
        await model.describe(plugin)
        #expect(await server.calls(to: "plugin-management.describePlugin").count == 2)
    }

    @Test func uneNouvelleTentativeEffaceUneErreurPerimee() async throws {
        let server = try await pluginsServer()
        let calls = Counter()
        await server.on("plugin-management.describePlugin") { _ in
            if calls.next() == 1 { throw FakeRemoteError("Plugin not found: x") }
            return try read("004")
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let plugins = model.overview?.availablePlugins ?? []
        try #require(plugins.count >= 2)
        await model.describe(plugins[0])
        #expect(model.actionError != nil)
        // Erreur non acquittée : l'ouverture d'un autre détail ne doit pas la faire réapparaître.
        await model.describe(plugins[1])
        #expect(model.descriptions[plugins[1].id] != nil)
        #expect(model.actionError == nil)
    }

    @Test func unAppelIgnoreNEffacePasLErreur() async throws {
        let server = try await pluginsServer()
        let calls = Counter()
        await server.on("plugin-management.describePlugin") { _ in
            if calls.next() == 2 { throw FakeRemoteError("Plugin not found: x") }
            return try read("004")
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let plugins = model.overview?.availablePlugins ?? []
        try #require(plugins.count >= 2)
        await model.describe(plugins[0])
        await model.describe(plugins[1])
        #expect(model.actionError != nil)
        // Déjà en cache : l'appel est ignoré et l'erreur affichée reste.
        await model.describe(plugins[0])
        #expect(model.actionError != nil)
    }

    @Test func descriptionRefuseeParLHote() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.describePlugin") { _ in
            .object(["components": .array([]), "diagnostics": .array([
                .object(["code": .string("describe_failed"), "message": .string("paquet illisible"), "severity": .string("error")]),
            ])])
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let plugin = try #require(model.overview?.availablePlugins.first)
        await model.describe(plugin)
        #expect(model.actionError == "L'hôte a signalé : paquet illisible")
    }

    @Test func capaciteNonPriseEnCharge() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.getPluginsOverview") { _ in
            .object(["capability": .object(["supported": .bool(false), "reason": .string("ZCode trop ancien")])])
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        #expect(model.phase == .failed("Gestion des plugins non prise en charge par cet hôte (ZCode trop ancien)."))
        #expect(model.overview == nil)
        #expect(model.isReadOnly)
        #expect(!model.isOffline)
    }

    @Test func hoteInjoignable() async throws {
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: ServerQueue([])))
        let model = PluginsModel(connection: connection, scope: .user)
        await model.loadIfNeeded()
        guard case .failed(let message) = model.phase else { Issue.record("échec attendu"); return }
        #expect(message.hasPrefix("Plugins indisponibles : "))
        #expect(model.isReadOnly)
        #expect(model.overview == nil)
        #expect(model.details.isEmpty)
    }

    @Test func listeGardeeHorsLigne() async throws {
        let server = try await readyServer()
        let calls = Counter()
        await server.on("plugin-management.getPluginsOverview") { _ in
            if calls.next() == 1 { return try read("001") }
            throw FakeRemoteError("panne")
        }
        await server.on("plugin-management.listPlugins") { _ in try read("003") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        #expect(model.phase == .ready)
        let first = try #require(model.overview)
        let details = model.details
        await model.refresh()
        #expect(model.phase == .failed("Plugins indisponibles : panne"))
        #expect(model.overview == first)
        #expect(model.details == details)
        #expect(model.isReadOnly)
        #expect(!model.isOffline)                                            // refus de l'hôte : pas une panne de connexion
    }

    @Test func listeEnEchecGardeLApercuPrecedent() async throws {
        let server = try await readyServer()
        let calls = Counter()
        await server.on("plugin-management.getPluginsOverview") { _ in try read("001") }
        await server.on("plugin-management.listPlugins") { _ in
            if calls.next() == 1 { return try read("003") }
            throw FakeRemoteError("détail illisible")
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let details = model.details
        await model.refresh()
        #expect(model.phase == .failed("Plugins indisponibles : détail illisible"))
        #expect(model.details == details)
    }

    @Test func nouvelEssaiApresUnEchec() async throws {
        let server = try await readyServer()
        let calls = Counter()
        await server.on("plugin-management.getPluginsOverview") { _ in
            if calls.next() == 1 { throw FakeRemoteError("panne") }
            return try read("001")
        }
        await server.on("plugin-management.listPlugins") { _ in try read("003") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        guard case .failed = model.phase else { Issue.record("échec attendu"); return }
        await model.loadIfNeeded()
        #expect(model.phase == .ready)
        await model.loadIfNeeded()                                           // déjà lue : relue en silence
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 3)
    }

    @Test func lesMessagesNeSEffacentQuAuPremierChargementOuALActualisation() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.describePlugin") { _ in throw FakeRemoteError("Plugin not found: x") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let plugin = try #require(model.overview?.availablePlugins.first)
        await model.describe(plugin)
        #expect(model.actionError != nil)
        await model.loadIfNeeded()                                           // redémarrage de `.task` : l'erreur reste
        #expect(model.actionError != nil)
        await model.refresh()                                                // actualisation explicite : tout s'efface
        #expect(model.actionError == nil)
    }

    // MARK: - Opérations

    @Test func installationPuisRelecture() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.installPlugin") { _ in try lifecycle("005") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.install(probe)
        #expect(await server.calls(to: "plugin-management.installPlugin") == [.object([
            "workspacePath": .string(testWorkspacePath), "marketplace": .string("zcode-ios-probe-market"),
            "pluginName": .string("zcode-ios-probe"), "operationId": .string("op-1"),
        ])])
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)       // lecture, puis relecture
        #expect(await server.calls(to: "plugin-management.listPlugins").count == 2)
        #expect(model.notice == "« zcode-ios-probe » installé. " + ExtensionsLabels.pluginsTakeEffect)
        #expect(model.actionError == nil)
        #expect(model.operation == nil)
        #expect(model.phase == .ready)
    }

    @Test func installationAvecDiagnosticDErreur() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.installPlugin") { _ in errorDiagnostics("plugin_archive_fetch_failed", "archive unavailable") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.install(probe)
        #expect(model.actionError == "L'hôte a signalé : archive unavailable")
        #expect(model.notice == nil)
        #expect(model.operation == nil)
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)       // relue malgré l'échec
    }

    @Test func connexionPerduePendantLInstallation() async throws {
        let first = try await pluginsServer()
        let cut = first.transport
        await first.on("plugin-management.installPlugin") { _ in
            cut.finish()                                                     // coupure : la réponse ne partira jamais
            return .null
        }
        let second = try await pluginsServer()
        let model = makeModel(ServerQueue([first, second]))
        await model.loadIfNeeded()
        await model.install(probe)
        #expect(model.actionError == "Connexion perdue pendant l'opération : l'hôte l'a peut-être terminée. Liste relue.")
        #expect(model.notice == nil)
        #expect(model.operation == nil)
        #expect(await second.calls(to: "plugin-management.getPluginsOverview").count == 1)       // relue après reconnexion
        #expect(model.phase == .ready)
    }

    @Test func annulationDUneInstallation() async throws {
        let server = try await pluginsServer()
        await server.onDeferred("plugin-management.installPlugin")
        await server.on("plugin-management.cancelPluginOperation") { _ in
            .object(["operationId": .string("op-1"), "cancelled": .bool(true)])
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let install = Task { await model.install(probe) }
        _ = try await eventually { await server.calls(to: "plugin-management.installPlugin").isEmpty ? nil : true }
        #expect(model.operation == PluginOperation(kind: .install, targetId: probe.id, operationId: "op-1", startedAt: startDate))

        await model.cancelOperation()
        #expect(await server.calls(to: "plugin-management.cancelPluginOperation") == [.object(["operationId": .string("op-1")])])
        #expect(model.notice == "Annulation demandée.")
        #expect(model.operation != nil)                                      // l'installation n'est pas encore terminée

        await server.respondDeferred("plugin-management.installPlugin", errorDiagnostics("plugin_operation_cancelled", "cancelled"))
        await install.value
        #expect(model.actionError == "Opération annulée.")
        #expect(model.operation == nil)
    }

    @Test func rienAAnnuler() async throws {
        let server = try await pluginsServer()
        await server.onDeferred("plugin-management.installPlugin")
        await server.on("plugin-management.cancelPluginOperation") { _ in
            .object(["operationId": .string("op-1"), "cancelled": .bool(false)])
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let install = Task { await model.install(probe) }
        _ = try await eventually { await server.calls(to: "plugin-management.installPlugin").isEmpty ? nil : true }
        await model.cancelOperation()
        #expect(model.notice == "Rien à annuler : l'opération est déjà terminée.")
        await server.respondDeferred("plugin-management.installPlugin", try lifecycle("005"))
        await install.value
        #expect(model.notice == "« zcode-ios-probe » installé. " + ExtensionsLabels.pluginsTakeEffect)
    }

    @Test func annulerSansOperationNEnvoieRien() async throws {
        let server = try await pluginsServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.cancelOperation()
        #expect(await server.calls(to: "plugin-management.cancelPluginOperation").isEmpty)
        #expect(model.notice == nil)
    }

    @Test func uneOperationALaFois() async throws {
        let server = try await pluginsServer()
        await server.onDeferred("plugin-management.installPlugin")
        await server.on("plugin-management.updatePlugin") { _ in try lifecycle("015") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let install = Task { await model.install(probe) }
        _ = try await eventually { await server.calls(to: "plugin-management.installPlugin").isEmpty ? nil : true }
        await model.install(probe)
        await model.update(installedProbe)
        await model.uninstall(installedProbe)
        await model.setEnabled(installedProbe, true)
        #expect(await server.calls(to: "plugin-management.installPlugin").count == 1)
        // La seule lecture initiale ; l'aperçu et la liste partent en parallèle, donc dans un ordre quelconque.
        #expect(await server.callNames(prefix: "plugin-management.").filter { $0 != "plugin-management.installPlugin" }.sorted()
            == ["plugin-management.getPluginsOverview", "plugin-management.listPlugins"])
        await server.respondDeferred("plugin-management.installPlugin", try lifecycle("005"))
        await install.value
        #expect(model.operation == nil)
    }

    @Test func horsLigneAucuneOperation() async throws {
        let server = try await pluginsServer()
        let model = makeModel(server)                                        // jamais lu : lecture seule
        await model.install(probe)
        #expect(await server.calls(to: "plugin-management.installPlugin").isEmpty)
        #expect(model.operation == nil)
    }

    @Test func miseAJourAvecPluginId() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.updatePlugin") { _ in try lifecycle("015") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.update(installedProbe)
        #expect(await server.calls(to: "plugin-management.updatePlugin") == [.object([
            "workspacePath": .string(testWorkspacePath), "pluginId": .string("p@m"),
        ])])
        #expect(model.notice == "« p » mis à jour. " + ExtensionsLabels.pluginsTakeEffect)
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)
    }

    @Test func activationDansLeProjet() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.setPluginEnabled") { _ in try lifecycle("009") }
        let model = makeModel(server, scope: .workspace("/w"))
        await model.loadIfNeeded()
        await model.setEnabled(installedProbe, true)
        #expect(await server.calls(to: "plugin-management.setPluginEnabled") == [.object([
            "workspacePath": .string("/w"), "pluginId": .string("p@m"), "enabled": .bool(true), "scope": .string("workspace"),
        ])])
        #expect(model.notice == "Activé pour Projet w. " + ExtensionsLabels.pluginsTakeEffect)
        await model.setEnabled(installedProbe, false)
        #expect(model.notice == "Désactivé pour Projet w. " + ExtensionsLabels.pluginsTakeEffect)
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 3)
    }

    @Test func activationPourLUtilisateur() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.setPluginEnabled") { _ in try lifecycle("009") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.setEnabled(installedProbe, false)
        #expect(await server.calls(to: "plugin-management.setPluginEnabled") == [.object([
            "workspacePath": .string(testWorkspacePath), "pluginId": .string("p@m"), "enabled": .bool(false),
            "scope": .string("user"),
        ])])
        #expect(model.notice == "Désactivé pour Utilisateur. " + ExtensionsLabels.pluginsTakeEffect)
    }

    @Test func configurationPuisRelecture() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.configurePlugin") { _ in try lifecycle("007") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        var form = PluginConfigForm(scope: .user, plugin: configurable)
        form.set(.value("x"), for: "label")
        let saved = await model.configure(installedProbe, form: form)
        #expect(saved)
        #expect(await server.calls(to: "plugin-management.configurePlugin") == [.object([
            "workspacePath": .string(testWorkspacePath), "pluginId": .string("p@m"),
            "options": .object(["label": .string("x")]), "scope": .string("user"),
        ])])
        #expect(model.notice == "Configuration de « p » enregistrée. " + ExtensionsLabels.pluginsTakeEffect)
        #expect(model.actionError == nil)
        #expect(model.operation == nil)
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)
    }

    @Test func effacementEtProjetDansLaRequete() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.configurePlugin") { _ in try lifecycle("007") }
        let model = makeModel(server, scope: .workspace("/w"))
        await model.loadIfNeeded()
        var form = PluginConfigForm(scope: .workspace("/w"), plugin: configuredInProject)
        form.set(.clear, for: "codeFactice")
        #expect(await model.configure(installedProbe, form: form))
        #expect(await server.calls(to: "plugin-management.configurePlugin") == [.object([
            "workspacePath": .string("/w"), "pluginId": .string("p@m"), "options": .object([:]),
            "clearOptionKeys": .array([.string("codeFactice")]), "scope": .string("workspace"),
        ])])
    }

    @Test func formulaireDUneAutrePorteeRefuse() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.configurePlugin") { _ in try lifecycle("007") }
        let model = makeModel(server, scope: .workspace("/w"))
        await model.loadIfNeeded()
        var form = PluginConfigForm(scope: .user, plugin: configurable)
        form.set(.value("x"), for: "label")
        #expect(await model.configure(installedProbe, form: form) == false)
        #expect(await server.calls(to: "plugin-management.configurePlugin").isEmpty)
    }

    @Test func configurationInutileOuInvalideNEnvoieRien() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.configurePlugin") { _ in try lifecycle("007") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        var form = PluginConfigForm(scope: .user, plugin: configurable)
        #expect(await model.configure(installedProbe, form: form) == false)          // rien de modifié
        form.set(.value("deux"), for: "timeout")
        #expect(await model.configure(installedProbe, form: form) == false)          // « Nombre attendu. »
        #expect(await server.calls(to: "plugin-management.configurePlugin").isEmpty)
        #expect(model.operation == nil)
    }

    @Test func configurationHorsLigneOuRefusee() async throws {
        let offline = try await pluginsServer()
        let model = makeModel(offline)                                                 // jamais lue : lecture seule
        var form = PluginConfigForm(scope: .user, plugin: configurable)
        form.set(.value("x"), for: "label")
        #expect(await model.configure(installedProbe, form: form) == false)
        await model.resetConfig(installedProbe)
        #expect(await offline.calls(to: "plugin-management.configurePlugin").isEmpty)
        #expect(await offline.calls(to: "plugin-management.resetPluginConfig").isEmpty)

        let server = try await pluginsServer()
        await server.on("plugin-management.configurePlugin") { _ in
            .object(["pluginId": .string("p@m"), "diagnostics": .array([
                .object(["code": .string("bad"), "message": .string("refusé"), "severity": .string("error")]),
            ])])
        }
        let refused = makeModel(server)
        await refused.loadIfNeeded()
        #expect(await refused.configure(installedProbe, form: form) == false)
        #expect(refused.actionError == "L'hôte a signalé : refusé")
        #expect(refused.notice == nil)
        #expect(refused.operation == nil)
    }

    @Test func reinitialisationDansLeProjet() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.resetPluginConfig") { _ in try lifecycle("012") }
        let model = makeModel(server, scope: .workspace("/w"))
        await model.loadIfNeeded()
        await model.resetConfig(installedProbe)
        #expect(await server.calls(to: "plugin-management.resetPluginConfig") == [.object([
            "workspacePath": .string("/w"), "pluginId": .string("p@m"), "scope": .string("workspace"),
        ])])
        #expect(model.notice == "Configuration de « p » réinitialisée. " + ExtensionsLabels.pluginsTakeEffect)
        #expect(model.operation == nil)
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)
    }

    @Test func reinitialisationRefuseePendantUneOperation() async throws {
        let server = try await pluginsServer()
        await server.onDeferred("plugin-management.updatePlugin")
        await server.on("plugin-management.resetPluginConfig") { _ in try lifecycle("012") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let running = Task { await model.update(installedProbe) }
        _ = try await eventually { await server.calls(to: "plugin-management.updatePlugin").isEmpty ? nil : true }
        // Refus silencieux : ni requête, ni erreur, mais `false` pour que l'appelant ne croie pas à un succès.
        let reset = await model.resetConfig(installedProbe)
        #expect(reset == false)
        #expect(await server.calls(to: "plugin-management.resetPluginConfig").isEmpty)
        #expect(model.actionError == nil)
        await server.respondDeferred("plugin-management.updatePlugin", try lifecycle("015"))
        await running.value
        // Libre : la réinitialisation part et rend `true`.
        #expect(await model.resetConfig(installedProbe))
        #expect(await server.calls(to: "plugin-management.resetPluginConfig").count == 1)
    }

    @Test func peutDemarrerUneOperation() async throws {
        let server = try await pluginsServer()
        let model = makeModel(server)
        #expect(!model.canStartOperation)                                              // jamais lue
        await model.loadIfNeeded()
        #expect(model.canStartOperation)
        await server.onDeferred("plugin-management.updatePlugin")
        let running = Task { await model.update(installedProbe) }
        _ = try await eventually { await server.calls(to: "plugin-management.updatePlugin").isEmpty ? nil : true }
        #expect(!model.canStartOperation)                                              // opération en cours
        await server.respondDeferred("plugin-management.updatePlugin", try lifecycle("015"))
        await running.value
        #expect(model.canStartOperation)
    }

    @Test func desinstallationEtRetablissement() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.uninstallPlugin") { _ in try lifecycle("018") }
        await server.on("plugin-management.restoreBuiltinPlugin") { _ in
            .object(["pluginId": .string("p@m"), "diagnostics": .array([])])
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.uninstall(installedProbe)
        #expect(await server.calls(to: "plugin-management.uninstallPlugin") == [.object([
            "workspacePath": .string(testWorkspacePath), "pluginId": .string("p@m"),
        ])])
        #expect(model.notice == "« p » désinstallé. " + ExtensionsLabels.pluginsTakeEffect)
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)

        await model.restore(AvailablePlugin(id: "p@m", name: "p", marketplace: "m"))
        #expect(await server.calls(to: "plugin-management.restoreBuiltinPlugin") == [.object([
            "workspacePath": .string(testWorkspacePath), "pluginId": .string("p@m"),
        ])])
        #expect(model.notice == "« p » rétabli. " + ExtensionsLabels.pluginsTakeEffect)
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 3)
    }

    @Test func desinstallationRefuseeParLHote() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.uninstallPlugin") { _ in
            .object(["diagnostics": .array([.object([
                "code": .string("plugin_in_use"), "message": .string("en cours d'utilisation"), "severity": .string("error"),
            ])])])
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.uninstall(installedProbe)
        #expect(model.actionError == "L'hôte a signalé : en cours d'utilisation")
        #expect(model.notice == nil)
    }

    @Test func appelEnErreurDansUneOperation() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.updatePlugin") { _ in throw FakeRemoteError("Plugin not found: p@m") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.update(installedProbe)
        #expect(model.actionError == "Plugin introuvable sur l'hôte.")
        #expect(model.notice == nil)
        #expect(model.operation == nil)
    }

    @Test func lAvisEtLErreurDeLOperationSurvivent() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.installPlugin") { _ in try lifecycle("005") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.install(probe)
        let notice = model.notice
        #expect(notice != nil)
        await model.loadIfNeeded()                                           // retour sur l'écran : l'avis reste
        #expect(model.notice == notice)
        await model.describe(probe)                                          // ouverture d'un détail : idem pour l'erreur
        await model.refresh()                                                // actualisation explicite : tout s'efface
        #expect(model.notice == nil)
        #expect(model.actionError == nil)
    }

    @Test func echecDeLAnnulationEtLectureDUnDetailPendantLOperation() async throws {
        let server = try await pluginsServer()
        await server.onDeferred("plugin-management.installPlugin")
        await server.on("plugin-management.cancelPluginOperation") { _ in throw FakeRemoteError("panne") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let install = Task { await model.install(probe) }
        _ = try await eventually { await server.calls(to: "plugin-management.installPlugin").isEmpty ? nil : true }
        await model.cancelOperation()
        #expect(model.actionError == "panne")
        // Ouvrir un détail pendant l'opération n'efface pas son erreur.
        await model.describe(AvailablePlugin(id: "b@m", name: "b", marketplace: "m"))
        #expect(model.actionError == "panne")
        await server.respondDeferred("plugin-management.installPlugin", try lifecycle("005"))
        await install.value
        #expect(model.actionError == "panne")                                // la fin de l'opération ne l'efface pas non plus
    }

    @Test func uneNouvelleOperationEffaceLesMessagesPrecedents() async throws {
        let server = try await pluginsServer()
        let calls = Counter()
        await server.on("plugin-management.updatePlugin") { _ in
            if calls.next() == 1 { throw FakeRemoteError("panne") }
            return try lifecycle("015")
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.update(installedProbe)
        #expect(model.actionError == "panne")
        await model.update(installedProbe)
        #expect(model.actionError == nil)
        #expect(model.notice != nil)
    }

    // MARK: - Sources

    @Test func ajoutDUneSourceAvecVerification() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.addPluginMarketplace", addHandler())
        let model = makeModel(server)
        await model.loadIfNeeded()
        let path = "/Users/me/claude/.zcode-check/marketplace"
        #expect(await model.validateSource("  \(path)\n") == nil)
        #expect(await server.calls(to: "plugin-management.addPluginMarketplace") == [.object([
            "workspacePath": .string(testWorkspacePath), "source": .string(path), "dryRun": .bool(true),
        ])])
        #expect(model.notice == nil)                                         // une vérification n'est pas une opération
        #expect(model.operation == nil)
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 1)

        #expect(await model.addSource(" \(path) "))
        #expect(await server.calls(to: "plugin-management.addPluginMarketplace").last == .object([
            "workspacePath": .string(testWorkspacePath), "source": .string(path), "operationId": .string("op-1"),
        ]))                                                                  // aucune clé dryRun
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)       // relecture
        #expect(await server.calls(to: "plugin-management.listPlugins").count == 2)
        #expect(model.notice == "Source « zcode-ios-probe-market » ajoutée. " + ExtensionsLabels.pluginsTakeEffect)
        #expect(model.actionError == nil)
        #expect(model.operation == nil)
    }

    @Test func ajoutAnnulable() async throws {
        let server = try await pluginsServer()
        await server.onDeferred("plugin-management.addPluginMarketplace")
        await server.on("plugin-management.cancelPluginOperation") { _ in
            .object(["operationId": .string("op-1"), "cancelled": .bool(true)])
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let add = Task { await model.addSource("owner/repo") }
        _ = try await eventually { await server.calls(to: "plugin-management.addPluginMarketplace").isEmpty ? nil : true }
        #expect(model.operation == PluginOperation(kind: .addSource, targetId: "owner/repo", operationId: "op-1", startedAt: startDate))
        await model.cancelOperation()
        #expect(await server.calls(to: "plugin-management.cancelPluginOperation") == [.object(["operationId": .string("op-1")])])
        await server.respondDeferred("plugin-management.addPluginMarketplace", marketplaceError("plugin_operation_cancelled", "x"))
        let added = await add.value
        #expect(added == false)
        #expect(model.actionError == "Opération annulée.")
        #expect(model.operation == nil)
    }

    @Test func verificationRefuseeOuEnEchec() async throws {
        let server = try await pluginsServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        await server.on("plugin-management.addPluginMarketplace") { _ in marketplaceError("marketplace_invalid", "catalogue illisible") }
        #expect(await model.validateSource("/x") == "L'hôte a signalé : catalogue illisible")
        await server.on("plugin-management.addPluginMarketplace") { _ in throw FakeRemoteError("Marketplace path does not exist: /x") }
        #expect(await model.validateSource("/x") == "Ce chemin n'existe pas sur l'hôte.")
        // Une vérification ne touche ni l'avis ni l'erreur de l'écran.
        #expect(model.actionError == nil)
        #expect(model.notice == nil)
    }

    @Test func verificationSansProjet() async throws {
        let server = try await pluginsServer()
        let model = makeModel(server, workspaces: [])
        #expect(await model.validateSource("/x") == "l'hôte n'annonce aucun projet.")
        #expect(await server.calls(to: "plugin-management.addPluginMarketplace").isEmpty)
    }

    @Test func cheminRelatifRefuseSansAppel() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.addPluginMarketplace", addHandler())
        let model = makeModel(server)
        await model.loadIfNeeded()
        #expect(await model.validateSource("./mes-plugins") == "Chemin absolu attendu (sur l'hôte).")
        #expect(await model.validateSource("   ") == "Saisis une source.")
        #expect(await model.addSource("./mes-plugins") == false)
        #expect(model.actionError == "Chemin absolu attendu (sur l'hôte).")
        #expect(await model.addSource("../mes-plugins") == false)
        #expect(await model.addSource(" \n") == false)
        #expect(model.actionError == "Saisis une source.")
        #expect(await server.calls(to: "plugin-management.addPluginMarketplace").isEmpty)
        #expect(model.operation == nil)
    }

    @Test func controleDeLaSource() {
        #expect(PluginsModel.sourceIssue("") == "Saisis une source.")
        #expect(PluginsModel.sourceIssue(" \t\n") == "Saisis une source.")
        #expect(PluginsModel.sourceIssue("./a") == "Chemin absolu attendu (sur l'hôte).")
        #expect(PluginsModel.sourceIssue("  ../a") == "Chemin absolu attendu (sur l'hôte).")
        for accepted in ["owner/repo", "owner/repo#main", "https://exemple.org/m.json", "git@github.com:o/r.git", "/abs/m.json", "~/m"] {
            #expect(PluginsModel.sourceIssue(accepted) == nil, "\(accepted)")
        }
    }

    @Test func ajoutRefuseParLHote() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.addPluginMarketplace") { _ in marketplaceError("marketplace_invalid", "catalogue illisible") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        #expect(await model.addSource("/x") == false)
        #expect(model.actionError == "L'hôte a signalé : catalogue illisible")
        #expect(model.notice == nil)
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)       // relue malgré l'échec
    }

    @Test func ajoutSansRetourDeLHoteGardeLeTexteMasque() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.addPluginMarketplace") { _ in .object(["diagnostics": .array([])]) }
        let model = makeModel(server)
        await model.loadIfNeeded()
        #expect(await model.addSource("https://u:jeton@exemple.org/m.json"))
        #expect(model.notice == "Source « https://•••@exemple.org/m.json » ajoutée. " + ExtensionsLabels.pluginsTakeEffect)
    }

    @Test func ajoutHorsLigne() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.addPluginMarketplace", addHandler())
        let model = makeModel(server)
        #expect(await model.addSource("/x") == false)                        // jamais lu : lecture seule
        #expect(await server.calls(to: "plugin-management.addPluginMarketplace").isEmpty)
        #expect(model.actionError == nil)
    }

    @Test func sourceOfficielleNonRetirable() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.removePluginMarketplace") { _ in .object(["diagnostics": .array([])]) }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let official = try #require(model.overview?.marketplaces.first { $0.isOfficial })
        await model.removeSource(official)
        #expect(await server.calls(to: "plugin-management.removePluginMarketplace").isEmpty)
        #expect(model.actionError == "Les sources officielles ne se retirent pas.")
        #expect(model.notice == nil)
        #expect(model.operation == nil)
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 1)       // aucune relecture
    }

    @Test func retraitPuisRelecture() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.removePluginMarketplace") { _ in try lifecycle("019") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.removeSource(MarketplaceSummary(id: "zcode-ios-probe-market", name: "zcode-ios-probe-market"))
        #expect(await server.calls(to: "plugin-management.removePluginMarketplace") == [.object([
            "workspacePath": .string(testWorkspacePath), "marketplace": .string("zcode-ios-probe-market"),
        ])])
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)
        #expect(await server.calls(to: "plugin-management.listPlugins").count == 2)
        #expect(model.notice == "Source retirée ; ses plugins installés restent, sans mises à jour. "
            + ExtensionsLabels.pluginsTakeEffect)
        #expect(model.actionError == nil)
        #expect(model.operation == nil)
    }

    @Test func retraitRefuseParLeDiagnostic() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.removePluginMarketplace") { _ in marketplaceError("marketplace_in_use", "utilisée") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.removeSource(MarketplaceSummary(id: "m", name: "m"))
        #expect(model.actionError == "L'hôte a signalé : utilisée")
        #expect(model.notice == nil)
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)
    }

    @Test func retraitHorsLigneNEnvoieRien() async throws {
        let server = try await pluginsServer()
        let model = makeModel(server)
        await model.removeSource(MarketplaceSummary(id: "m", name: "m"))
        #expect(await server.calls(to: "plugin-management.removePluginMarketplace").isEmpty)
    }

    @Test func actualisationDeToutesLesSources() async throws {
        let server = try await pluginsServer()
        await server.onDeferred("plugin-management.updatePluginMarketplace")
        await server.on("plugin-management.cancelPluginOperation") { _ in
            .object(["operationId": .string("op-1"), "cancelled": .bool(true)])
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let refresh = Task { await model.refreshSources() }
        _ = try await eventually { await server.calls(to: "plugin-management.updatePluginMarketplace").isEmpty ? nil : true }
        #expect(await server.calls(to: "plugin-management.updatePluginMarketplace") == [.object([
            "workspacePath": .string(testWorkspacePath), "operationId": .string("op-1"),       // aucune clé marketplace
        ])])
        #expect(model.operation?.kind == .refreshSources)
        #expect(model.operation?.operationId == "op-1")                      // annulable
        await model.cancelOperation()
        #expect(await server.calls(to: "plugin-management.cancelPluginOperation") == [.object(["operationId": .string("op-1")])])
        await server.respondDeferred("plugin-management.updatePluginMarketplace", try lifecycle("014"))
        await refresh.value
        #expect(model.notice == "Sources actualisées. " + ExtensionsLabels.pluginsTakeEffect)
        #expect(model.operation == nil)
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)
    }

    @Test func actualisationEnEchec() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.updatePluginMarketplace") { _ in
            .object(["marketplaces": .array([]), "diagnostics": .array([.object([
                "code": .string("marketplace_refresh_failed"), "message": .string("réseau"), "severity": .string("error"),
            ])])])
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.refreshSources()
        #expect(model.actionError == "Actualisation de la source impossible.")
        #expect(model.notice == nil)
        #expect(model.operation == nil)
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)
    }

    @Test func sourceInexistante() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.updatePluginMarketplace") { _ in throw FakeRemoteError("Marketplace not found: x") }
        await server.on("plugin-management.removePluginMarketplace") { _ in throw FakeRemoteError("Marketplace not found: x") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.refreshSources()
        #expect(model.actionError == "Source introuvable (retirée entre-temps ?).")
        await model.removeSource(MarketplaceSummary(id: "x", name: "x"))
        #expect(model.actionError == "Source introuvable (retirée entre-temps ?).")
        #expect(model.operation == nil)
    }

    @Test func uneSeuleOperationDeSource() async throws {
        let server = try await pluginsServer()
        await server.onDeferred("plugin-management.updatePluginMarketplace")
        let model = makeModel(server)
        await model.loadIfNeeded()
        let refresh = Task { await model.refreshSources() }
        _ = try await eventually { await server.calls(to: "plugin-management.updatePluginMarketplace").isEmpty ? nil : true }
        #expect(await model.addSource("/x") == false)
        await model.removeSource(MarketplaceSummary(id: "m", name: "m"))
        await model.refreshSources()
        #expect(await server.calls(to: "plugin-management.updatePluginMarketplace").count == 1)
        #expect(await server.calls(to: "plugin-management.addPluginMarketplace").isEmpty)
        #expect(await server.calls(to: "plugin-management.removePluginMarketplace").isEmpty)
        await server.respondDeferred("plugin-management.updatePluginMarketplace", try lifecycle("014"))
        await refresh.value
    }

    @Test func composantsQuiLancentDesProgrammes() async throws {
        let server = try await pluginsServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        #expect(!model.hasRunnableComponents(AvailablePlugin(id: "a@m", name: "a", marketplace: "m", componentTypes: [.skill, .command])))
        #expect(model.hasRunnableComponents(AvailablePlugin(id: "a@m", name: "a", marketplace: "m", componentTypes: [.skill, .hook])))
        #expect(model.hasRunnableComponents(AvailablePlugin(id: "a@m", name: "a", marketplace: "m", componentTypes: [.mcp])))
        // Sans type annoncé, les composants lus par `describe` décident.
        await server.on("plugin-management.describePlugin") { _ in
            .object(["components": .array([.object([
                "kind": .string("hook"), "items": .array([.object(["name": .string("PreToolUse")])]),
            ])])])
        }
        let bare = AvailablePlugin(id: "b@m", name: "b", marketplace: "m")
        #expect(!model.hasRunnableComponents(bare))
        await model.describe(bare)
        #expect(model.hasRunnableComponents(bare))
    }
}

struct PluginLabelsTests {
    @Test func libellesDErreurPlugins() {
        let table: [(String, String)] = [
            ("Marketplace source is empty", "Saisis une source."),
            ("Marketplace path does not exist: /x", "Ce chemin n'existe pas sur l'hôte."),
            ("Marketplace file must be a .json file: /x", "Le fichier de la source doit être un .json."),
            ("Unsupported marketplace source: x", "Source non prise en charge par l'hôte."),
            ("Marketplace not found: x", "Source introuvable (retirée entre-temps ?)."),
            ("Plugin not found: x", "Plugin introuvable sur l'hôte."),
            ("Plugin name is ambiguous, use full plugin id: x", "Nom de plugin ambigu sur l'hôte."),
            ("Method not found: describePlugin", "Cette version de ZCode ne gère pas cette action."),
            ("Unknown channel", "Cette version de ZCode n'expose pas la gestion des plugins."),
            ("quelque chose d'autre", "quelque chose d'autre"),
            ("", "Erreur du serveur ZCode."),
        ]
        for (received, shown) in table {
            #expect(ExtensionsLabels.pluginFailure(remote(received)) == shown, "\(received)")
        }
        #expect(ExtensionsLabels.pluginFailure(remote("x", code: .number(-32601)))
            == "Cette version de ZCode ne gère pas cette action.")
        #expect(ExtensionsLabels.pluginFailure(remote("x", code: .string("-32601"))) == "x")
        #expect(ExtensionsLabels.pluginFailure(remote("Request timed out", name: "ZCodeProtocolRequestTimeoutError"))
            == "L'hôte n'a pas répondu à temps ; l'opération continue peut-être.")
        #expect(ExtensionsLabels.pluginFailure(RPCError.connectionClosed)
            == ConnectionFailure(RPCError.connectionClosed).message)
    }

    @Test func libelles() {
        #expect(ExtensionsLabels.category("developer-tools") == "Outils de développement")
        #expect(ExtensionsLabels.category("productivity") == "Productivité")
        #expect(ExtensionsLabels.category("finance") == "Finance")
        #expect(ExtensionsLabels.category("utilities") == "Utilitaires")
        #expect(ExtensionsLabels.category("autre") == "autre")
        let kinds: [(PluginComponentKind, String)] = [
            (.agent, "Sous-agents"), (.command, "Commandes"), (.skill, "Skills"), (.hook, "Hooks"),
            (.mcp, "Serveurs MCP"), (.lsp, "Serveurs LSP"), (PluginComponentKind(rawValue: "x"), "x"),
        ]
        for (kind, label) in kinds { #expect(ExtensionsLabels.componentKind(kind) == label) }
        #expect(ExtensionsLabels.marketplaceTitle(MarketplaceSummary(id: "zcode-plugins-official", name: "zcode-plugins-official"))
            == "Officiel ZCode")
        #expect(ExtensionsLabels.marketplaceTitle(MarketplaceSummary(id: "claude-plugins-official", name: "claude-plugins-official"))
            == "Officiel Claude")
        #expect(ExtensionsLabels.marketplaceTitle(MarketplaceSummary(id: "m1", name: "Mes plugins")) == "Mes plugins")
        #expect(ExtensionsLabels.marketplaceTitle(MarketplaceSummary(id: "m1", name: "")) == "m1")
        #expect(ExtensionsLabels.hostExecutionNote(hostName: "Mac") == "Les plugins s'exécutent sur Mac, jamais sur l'iPhone.")
        #expect(ExtensionsLabels.pluginsTakeEffect
            == "S'applique aux nouvelles sessions ; les conversations ouvertes gardent l'ancienne configuration.")
    }

    @Test func nomAffiche() {
        let listing = PluginListing(displayName: "Display", displayNameI18n: ["fr": "Affiché", "en": "Shown"])
        #expect(ExtensionsLabels.pluginDisplayName("nom", listing: listing) == "Affiché")
        #expect(ExtensionsLabels.pluginDisplayName("nom", listing: PluginListing(displayName: "Display")) == "Display")
        #expect(ExtensionsLabels.pluginDisplayName("nom", listing: PluginListing()) == "nom")
        #expect(ExtensionsLabels.pluginDisplayName("nom", listing: nil) == "nom")
        // Un nom affiché vide ne masque pas le nom du plugin.
        #expect(ExtensionsLabels.pluginDisplayName("nom", listing: PluginListing(displayName: "")) == "nom")
    }

    @Test func diagnostics() {
        #expect(ExtensionsLabels.diagnostic(PluginDiagnostic(code: "plugin_operation_cancelled", message: "x")) == "Opération annulée.")
        #expect(ExtensionsLabels.diagnostic(PluginDiagnostic(code: "marketplace_refresh_failed", message: "x"))
            == "Actualisation de la source impossible.")
        #expect(ExtensionsLabels.diagnostic(PluginDiagnostic(code: "autre", message: "détail")) == "L'hôte a signalé : détail")
    }

    @Test func texteDeMiseEnGarde() {
        let official = MarketplaceSummary(id: "zcode-plugins-official", name: "zcode-plugins-official", isOfficial: true)
        let personal = MarketplaceSummary(id: "m", name: "Mes plugins")
        let plugin = AvailablePlugin(id: "x@m", name: "x", marketplace: "m")
        let base = "Installer « x » sur Mac ? Le plugin s'exécutera sur Mac, jamais sur l'iPhone. "
            + "Il sera installé pour l'utilisateur et actif dans les nouvelles sessions."
        let hooks = " Il ajoute des commandes automatiques (hooks) ou des serveurs MCP qui lancent des programmes sur l'hôte."
        let unofficial = "Source non officielle : n'installe que du code de confiance. "
        func warning(_ marketplace: MarketplaceSummary?, _ runnable: Bool) -> String {
            ExtensionsLabels.installWarning(plugin: plugin, marketplace: marketplace, hostName: "Mac", hasRunnableComponents: runnable)
        }
        #expect(warning(official, false) == base)
        #expect(warning(official, true) == base + hooks)
        #expect(warning(personal, false) == unofficial + base)
        #expect(warning(personal, true) == unofficial + base + hooks)
        #expect(warning(nil, false) == unofficial + base)                    // source inconnue : prudence
        let named = AvailablePlugin(id: "x@m", name: "x", marketplace: "m", listing: PluginListing(displayNameI18n: ["fr": "Ex"]))
        #expect(ExtensionsLabels.installWarning(plugin: named, marketplace: official, hostName: "Mac", hasRunnableComponents: false)
            .hasPrefix("Installer « Ex » sur Mac ?"))
    }

    @Test func libellesDeSource() {
        #expect(ExtensionsLabels.sourceKind("github") == "GitHub")
        #expect(ExtensionsLabels.sourceKind("url") == "URL")
        #expect(ExtensionsLabels.sourceKind("directory") == "Chemin")
        #expect(ExtensionsLabels.sourceKind("file") == "Chemin")
        #expect(ExtensionsLabels.sourceKind("git") == "Git")
        #expect(ExtensionsLabels.sourceKind("npm") == "npm")                 // inconnu : gardé tel quel
    }

    @Test func masquageDesIdentifiantsDUneSource() {
        let table: [(String, String)] = [
            ("https://user:jeton@exemple.org/m.json", "https://•••@exemple.org/m.json"),
            ("https://jeton@exemple.org/m.git", "https://•••@exemple.org/m.git"),
            ("https://u:p@w@exemple.org:8443/x?a=b@c#d@e", "https://•••@exemple.org:8443/x?a=b@c#d@e"),
            ("HTTP://u:p@exemple.org", "HTTP://•••@exemple.org"),
            ("https://exemple.org/m@2.json", "https://exemple.org/m@2.json"),    // « @ » hors de l'autorité
            ("https://exemple.org", "https://exemple.org"),
            ("git@github.com:owner/repo.git", "git@github.com:owner/repo.git"),  // sans schéma : pas un secret
            ("owner/repo", "owner/repo"),
            ("/chemin/m.json", "/chemin/m.json"),
            ("", ""),
        ]
        for (raw, shown) in table { #expect(ExtensionsLabels.masked(raw) == shown, "\(raw)") }
        // Dans une phrase (échec d'actualisation qui cite l'adresse).
        #expect(ExtensionsLabels.masked("fetch https://u:t@h.org/r.git a échoué ; voir https://v:s@k.org/x")
            == "fetch https://•••@h.org/r.git a échoué ; voir https://•••@k.org/x")
        let summary = MarketplaceSummary(id: "m", name: "m", sourceKind: "url", sourceLabel: "https://u:t@h.org/m.json")
        #expect(ExtensionsLabels.sourceLabel(summary) == "https://•••@h.org/m.json")
        #expect(ExtensionsLabels.sourceLabel(MarketplaceSummary(id: "m", name: "m")) == nil)
        #expect(ExtensionsLabels.sourceLabel(MarketplaceSummary(id: "m", name: "m", sourceLabel: "")) == nil)
    }

    @Test func masquageDesParametresSensibles() {
        let table: [(String, String)] = [
            ("https://h.org/m.json?token=abc&v=2", "https://h.org/m.json?token=•••&v=2"),
            ("https://h.org/m.json?v=2&access_token=abc", "https://h.org/m.json?v=2&access_token=•••"),
            ("https://h.org/m.json?key=abc#frag", "https://h.org/m.json?key=•••#frag"),
            ("https://h.org/m.json?api_key=a&X-Amz-Signature=b&X-Amz-Credential=c&sig=d",
             "https://h.org/m.json?api_key=•••&X-Amz-Signature=•••&X-Amz-Credential=•••&sig=•••"),
            ("https://h.org/m.json?Client_Secret=a&password=b&auth=c", "https://h.org/m.json?Client_Secret=•••&password=•••&auth=•••"),
            ("https://u:t@h.org/m.json?token=abc", "https://•••@h.org/m.json?token=•••"),
            ("https://h.org/m.json?page=2&ref=main", "https://h.org/m.json?page=2&ref=main"),      // rien de sensible
            ("https://h.org/m.json?token=", "https://h.org/m.json?token="),                        // aucune valeur
        ]
        for (raw, shown) in table { #expect(ExtensionsLabels.masked(raw) == shown, "\(raw)") }
        // Dans une phrase : la valeur s'arrête à l'espace.
        #expect(ExtensionsLabels.masked("Marketplace redirect is missing Location header: https://h.org/m?token=abc suite")
            == "Marketplace redirect is missing Location header: https://h.org/m?token=••• suite")
    }

    /// Un message de l'hôte (diagnostic, erreur d'appel, motif de refus) qui cite une adresse de source est masqué avant
    /// tout affichage : l'hôte écrit l'adresse brute (`marketplace.ts`, « redirect is missing Location header: … »).
    @Test func lesMessagesDeLHoteSontMasques() {
        let raw = "Marketplace redirect is missing Location header: https://u:t@h/m.json?token=abc"
        let shown = "Marketplace redirect is missing Location header: https://•••@h/m.json?token=•••"
        #expect(ExtensionsLabels.diagnostic(PluginDiagnostic(code: "marketplace_fetch_failed", message: raw))
            == "L'hôte a signalé : " + shown)
        #expect(ExtensionsLabels.pluginFailure(remote(raw)) == shown)
        #expect(ExtensionsLabels.pluginFailure(RPCError.protocolViolation(raw)).contains("https://u:t@h/") == false)
    }

    @MainActor @Test func diagnosticDErreurMasqueDansLAlerte() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.addPluginMarketplace") { _ in
            marketplaceError("marketplace_fetch_failed", "Marketplace redirect is missing Location header: https://u:t@h/m.json")
        }
        let model = makeModel(server)
        await model.loadIfNeeded()
        #expect(await model.addSource("https://u:t@h/m.json") == false)
        #expect(model.actionError == "L'hôte a signalé : Marketplace redirect is missing Location header: https://•••@h/m.json")
        #expect(await model.validateSource("https://u:t@h/m.json")
            == "L'hôte a signalé : Marketplace redirect is missing Location header: https://•••@h/m.json")
    }

    @MainActor @Test func motifDeRefusMasque() async throws {
        let server = try await readyServer()
        await server.on("plugin-management.getPluginsOverview") { _ in
            .object(["capability": .object(["supported": .bool(false), "reason": .string("source https://u:t@h/ refusée")])])
        }
        await server.on("plugin-management.listPlugins") { _ in try read("003") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        #expect(model.phase == .failed("Gestion des plugins non prise en charge par cet hôte (source https://•••@h/ refusée)."))
    }

    @Test func lesEnTetesDUneSourceNeSontJamaisLus() throws {
        let json: JSONValue = .object([
            "id": .string("m"), "name": .string("m"),
            "source": .object(["source": .string("url"), "url": .string("https://h.org/m.json"),
                               "headers": .object(["Authorization": .string("Bearer SECRET-CANARY")])]),
        ])
        let summary = try #require(MarketplaceSummary(json: json))
        #expect(!"\(summary)".contains("SECRET-CANARY"))
    }

    @Test func libellesDOperation() {
        let kinds: [(PluginOperation.Kind, String)] = [
            (.install, "Installation…"), (.update, "Mise à jour…"), (.uninstall, "Désinstallation…"),
            (.restore, "Rétablissement…"), (.enable, "Activation…"), (.disable, "Désactivation…"),
            (.configure, "Enregistrement de la configuration…"), (.reset, "Réinitialisation…"),
            (.addSource, "Ajout de la source…"), (.removeSource, "Retrait de la source…"),
            (.refreshSources, "Actualisation des sources…"),
        ]
        for (kind, label) in kinds { #expect(ExtensionsLabels.operation(kind) == label) }
        #expect(ExtensionsLabels.elapsed(0) == "0:00")
        #expect(ExtensionsLabels.elapsed(42.9) == "0:42")
        #expect(ExtensionsLabels.elapsed(65) == "1:05")
        #expect(ExtensionsLabels.elapsed(300) == "5:00")
        #expect(ExtensionsLabels.elapsed(-3) == "0:00")
    }
}

/// Relectures à la réapparition d'un écran : les opérations touchent tout l'hôte (installation pour l'utilisateur,
/// sources, désinstallation), et ZCode Web peut aussi changer l'hôte ; un modèle déjà lu se relit donc en silence.
@MainActor
struct PluginsModelRefreshTests {
    /// Faux hôte dont l'aperçu montre `zcode-ios-probe` installé une fois `installPlugin` reçu.
    private func installingServer() async throws -> FakeZCodeServer {
        let server = try await readyServer()
        let installed = Flag()
        await server.on("plugin-management.getPluginsOverview") { _ in try lifecycle(installed.isSet ? "010" : "003") }
        await server.on("plugin-management.listPlugins") { _ in try read("003") }
        await server.on("plugin-management.installPlugin") { _ in
            installed.set()
            return try lifecycle("005")
        }
        return server
    }

    private func installedIds(_ model: PluginsModel) -> [String] {
        model.overview?.installedPlugins.map(\.id) ?? []
    }

    @Test func uneInstallationEstVueDansLAutrePortee() async throws {
        let server = try await installingServer()
        // Une seule connexion pour les deux portées, comme `AppModel`.
        let connection = HostConnection(
            host: testHost, endpoint: testEndpoint,
            dependencies: makeDependencies(servers: ServerQueue([server])))
        let project = PluginsModel(connection: connection, scope: .workspace("/w"), makeOperationId: { "op-1" })
        let user = PluginsModel(connection: connection, scope: .user, makeOperationId: { "op-1" })
        await project.loadIfNeeded()
        #expect(!installedIds(project).contains(probe.id))
        await user.loadIfNeeded()
        await user.install(probe)
        #expect(installedIds(user).contains(probe.id))
        await project.loadIfNeeded()                                         // retour sur la portée Projet
        #expect(installedIds(project).contains(probe.id))
        #expect(project.phase == .ready)
    }

    @Test func relectureSilencieuseGardeLAvisEtLaListe() async throws {
        let server = try await installingServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.install(probe)
        let notice = try #require(model.notice)
        let overview = model.overview
        await server.onDeferred("plugin-management.getPluginsOverview")
        let reload = Task { await model.loadIfNeeded() }
        _ = try await eventually {
            await server.calls(to: "plugin-management.getPluginsOverview").count == 3 ? true : nil
        }
        // Pendant la relecture : ni chargement visible, ni lecture seule, ni avis effacé.
        #expect(model.phase == .ready)
        #expect(!model.isReadOnly)
        #expect(model.overview == overview)
        #expect(model.notice == notice)
        await server.respondDeferred("plugin-management.getPluginsOverview", try lifecycle("021"))
        await reload.value
        #expect(model.phase == .ready)
        #expect(model.notice == notice)
        #expect(!installedIds(model).contains(probe.id))                     // désinstallé ailleurs : relu
    }

    /// L'écran disparaît (détail poussé, autre rubrique) pendant la relecture : `.task` est annulé, mais la relecture
    /// silencieuse va à son terme au lieu d'afficher une erreur d'annulation.
    @Test func relectureSilencieuseNonAnnuleeParLaDisparitionDeLEcran() async throws {
        let server = try await installingServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        await server.onDeferred("plugin-management.getPluginsOverview")
        let reload = Task { await model.loadIfNeeded() }
        _ = try await eventually {
            await server.calls(to: "plugin-management.getPluginsOverview").count == 2 ? true : nil
        }
        reload.cancel()
        await server.respondDeferred("plugin-management.getPluginsOverview", try lifecycle("010"))
        await reload.value
        _ = try await eventually { installedIds(model).contains(probe.id) ? true : nil }
        #expect(model.phase == .ready)
    }

    @Test func relectureSilencieuseGardeLErreur() async throws {
        let server = try await pluginsServer()
        await server.on("plugin-management.describePlugin") { _ in throw FakeRemoteError("Plugin not found: x") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        await model.describe(try #require(model.overview?.availablePlugins.first))
        let error = try #require(model.actionError)
        await model.loadIfNeeded()
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)
        #expect(model.actionError == error)
    }

    @Test func aucuneRelecturePendantUneOperation() async throws {
        let server = try await pluginsServer()
        await server.onDeferred("plugin-management.installPlugin")
        let model = makeModel(server)
        await model.loadIfNeeded()
        let install = Task { await model.install(probe) }
        _ = try await eventually { await server.calls(to: "plugin-management.installPlugin").isEmpty ? nil : true }
        await model.loadIfNeeded()                                           // écran réaffiché pendant l'installation
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 1)
        await server.respondDeferred("plugin-management.installPlugin", try lifecycle("005"))
        await install.value
        #expect(await server.calls(to: "plugin-management.getPluginsOverview").count == 2)     // relecture de clôture
    }

    @Test func relectureSilencieuseEnEchecPasseEnLectureSeule() async throws {
        let server = try await readyServer()
        let calls = Counter()
        await server.on("plugin-management.getPluginsOverview") { _ in
            if calls.next() == 1 { return try read("001") }
            throw FakeRemoteError("panne")
        }
        await server.on("plugin-management.listPlugins") { _ in try read("003") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        let overview = model.overview
        await model.loadIfNeeded()
        #expect(model.phase == .failed("Plugins indisponibles : panne"))
        #expect(model.overview == overview)                                  // l'aperçu lu reste affiché
    }

    @Test func capaciteRetireeVideLApercu() async throws {
        let server = try await readyServer()
        let calls = Counter()
        await server.on("plugin-management.getPluginsOverview") { _ in
            if calls.next() == 1 { return try read("001") }
            return .object(["capability": .object(["supported": .bool(false)])])
        }
        await server.on("plugin-management.listPlugins") { _ in try read("003") }
        let model = makeModel(server)
        await model.loadIfNeeded()
        #expect(model.overview != nil)
        await model.refresh()
        #expect(model.phase == .failed("Gestion des plugins non prise en charge par cet hôte."))
        #expect(model.overview == nil)                                       // rien de périmé affiché comme « hors ligne »
        #expect(model.details.isEmpty)
        #expect(!model.isOffline)
    }

    @Test func horsLigneSeulementPourUnePanneDeConnexion() async throws {
        let server = try await pluginsServer()
        let model = makeModel(server)
        await model.loadIfNeeded()
        #expect(!model.isOffline)
        server.transport.finish()                                            // connexion coupée, aucun autre serveur
        await model.refresh()
        guard case .failed = model.phase else { Issue.record("échec attendu"); return }
        #expect(model.isOffline)
        #expect(model.overview != nil)
    }

    @Test func hoteInjoignableEstHorsLigne() async throws {
        let connection = HostConnection(host: testHost, endpoint: testEndpoint,
                                        dependencies: makeDependencies(servers: ServerQueue([])))
        let model = PluginsModel(connection: connection, scope: .user)
        await model.loadIfNeeded()
        #expect(model.isOffline)
    }
}
