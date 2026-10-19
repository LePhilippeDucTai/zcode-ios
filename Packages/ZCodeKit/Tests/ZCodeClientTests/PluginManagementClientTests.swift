import Foundation
import Testing
import ZCodeClient
import ZCodeRPC
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct PluginManagementClientTests {
    private let host = "/Users/u/claude"

    private func plugins(_ server: FakeZCodeServer) async -> PluginManagementClient {
        await server.start()
        let client = ChannelClient(transport: server.transport)
        await client.start()
        return PluginManagementClient(client: client, hostWorkspace: host)
    }

    private func record(_ folder: String, _ prefix: String) throws -> JSONValue {
        try Fixtures.record(in: "v3.15.1/\(folder)", prefix: prefix)
    }

    private func available(_ marketplace: String = "m", _ name: String = "p") -> AvailablePlugin {
        AvailablePlugin(id: "\(name)@\(marketplace)", name: name, marketplace: marketplace)
    }

    @Test func apercuSelonLaPortee() async throws {
        let server = FakeZCodeServer()
        let overview = try record("plugins-read", "001")
        await server.on("plugin-management.getPluginsOverview") { _ in overview }
        let client = await plugins(server)
        let result = try await client.overview(scope: .user)
        #expect(result.supported && !result.availablePlugins.isEmpty)
        _ = try await client.overview(scope: .workspace("/w"))
        #expect(await server.calls(to: "plugin-management.getPluginsOverview") == [
            .object(["workspacePath": .string(host), "configScope": .string("user")]),
            .object(["workspacePath": .string("/w"), "configScope": .string("workspace")]),
        ])
    }

    @Test func listeSelonLaPortee() async throws {
        let server = FakeZCodeServer()
        let list = try record("plugins-read", "003")
        await server.on("plugin-management.listPlugins") { _ in list }
        let client = await plugins(server)
        #expect(try await client.list(scope: .workspace("/w")).plugins.count == 16)
        _ = try await client.list(scope: .user)
        #expect(await server.calls(to: "plugin-management.listPlugins") == [
            .object(["workspacePath": .string("/w"), "configScope": .string("workspace")]),
            .object(["workspacePath": .string(host), "configScope": .string("user")]),
        ])
    }

    @Test func descriptionDUnPlugin() async throws {
        let server = FakeZCodeServer()
        let described = try record("plugins-lifecycle", "004")
        await server.on("plugin-management.describePlugin") { _ in described }
        let result = try await plugins(server).describe(available("zcode-ios-probe-market", "zcode-ios-probe"), scope: .user)
        #expect(result.components.first?.kind == .skill)
        #expect(await server.calls(to: "plugin-management.describePlugin") == [.object([
            "workspacePath": .string(host), "marketplace": .string("zcode-ios-probe-market"),
            "pluginName": .string("zcode-ios-probe"),
        ])])
    }

    @Test func installationSansPortee() async throws {
        let server = FakeZCodeServer()
        let installed = try record("plugins-lifecycle", "005")
        await server.on("plugin-management.installPlugin") { _ in installed }
        let result = try await plugins(server).install(available(), operationId: "op-1", scope: .workspace("/w"))
        #expect(result.failure == nil && result.installedPlugins.count == 1)
        #expect(await server.calls(to: "plugin-management.installPlugin") == [.object([
            "workspacePath": .string("/w"), "marketplace": .string("m"), "pluginName": .string("p"),
            "operationId": .string("op-1"),
        ])])
    }

    @Test func installationAvecDiagnosticRenvoyeLEchec() async throws {
        let server = FakeZCodeServer()
        let failed = try record("plugins-lifecycle", "016")
        await server.on("plugin-management.installPlugin") { _ in failed }
        let result = try await plugins(server).install(available(), operationId: "op-1", scope: .user)
        #expect(result.failure?.isError == true)
    }

    @Test func miseAJourToujoursAvecPluginId() async throws {
        let server = FakeZCodeServer()
        let updated = try record("plugins-lifecycle", "015")
        await server.on("plugin-management.updatePlugin") { _ in updated }
        let result = try await plugins(server).update(pluginId: "p@m", scope: .user)
        #expect(result.installedPlugins.count == 1)
        #expect(await server.calls(to: "plugin-management.updatePlugin") == [.object([
            "workspacePath": .string(host), "pluginId": .string("p@m"),
        ])])
    }

    @Test func desinstallationEtRestauration() async throws {
        let server = FakeZCodeServer()
        let removed = try record("plugins-lifecycle", "018")
        await server.on("plugin-management.uninstallPlugin") { _ in removed }
        await server.on("plugin-management.restoreBuiltinPlugin") { _ in
            .object(["pluginId": .string("p@m"), "diagnostics": .array([
                .object(["code": .string("c"), "message": .string("m"), "severity": .string("error")]),
            ])])
        }
        let client = await plugins(server)
        #expect(try await client.uninstall(pluginId: "p@m", scope: .workspace("/w")).isEmpty)
        let diagnostics = try await client.restoreBuiltin(pluginId: "p@m", scope: .user)
        #expect(diagnostics.first?.isError == true)
        #expect(await server.calls(to: "plugin-management.uninstallPlugin") == [.object([
            "workspacePath": .string("/w"), "pluginId": .string("p@m"),
        ])])
        #expect(await server.calls(to: "plugin-management.restoreBuiltinPlugin") == [.object([
            "workspacePath": .string(host), "pluginId": .string("p@m"),
        ])])
    }

    @Test func activationEtConfigurationDansLeProjet() async throws {
        let server = FakeZCodeServer()
        let enabled = try record("plugins-lifecycle", "009")
        await server.on("plugin-management.setPluginEnabled") { _ in enabled }
        await server.on("plugin-management.configurePlugin") { _ in .object(["pluginId": .string("p@m"), "diagnostics": .array([])]) }
        await server.on("plugin-management.resetPluginConfig") { _ in .object(["pluginId": .string("p@m"), "diagnostics": .array([])]) }
        let client = await plugins(server)
        try await client.setEnabled(pluginId: "p@m", false, scope: .workspace("/w"))
        #expect(await server.calls(to: "plugin-management.setPluginEnabled") == [.object([
            "workspacePath": .string("/w"), "pluginId": .string("p@m"), "enabled": .bool(false), "scope": .string("workspace"),
        ])])

        let options: [String: JSONValue] = ["label": .string("essai"), "nombre": .number(2), "actif": .bool(true)]
        #expect(try await client.configure(pluginId: "p@m", options: options, clearing: [], scope: .workspace("/w")).isEmpty)
        _ = try await client.configure(pluginId: "p@m", options: [:], clearing: ["codeFactice"], scope: .user)
        #expect(await server.calls(to: "plugin-management.configurePlugin") == [
            .object([
                "workspacePath": .string("/w"), "pluginId": .string("p@m"), "options": .object(options),
                "scope": .string("workspace"),
            ]),
            .object([
                "workspacePath": .string(host), "pluginId": .string("p@m"), "options": .object([:]),
                "clearOptionKeys": .array([.string("codeFactice")]), "scope": .string("user"),
            ]),
        ])

        #expect(try await client.resetConfig(pluginId: "p@m", scope: .user).isEmpty)
        #expect(await server.calls(to: "plugin-management.resetPluginConfig") == [.object([
            "workspacePath": .string(host), "pluginId": .string("p@m"), "scope": .string("user"),
        ])])
    }

    @Test func sources() async throws {
        let server = FakeZCodeServer()
        let dryRun = try record("plugins-lifecycle", "001")
        let added = try record("plugins-lifecycle", "002")
        let removed = try record("plugins-lifecycle", "019")
        let refreshed = try record("plugins-lifecycle", "014")
        await server.on("plugin-management.addPluginMarketplace") { params in
            params["dryRun"]?.boolValue == true ? dryRun : added
        }
        await server.on("plugin-management.removePluginMarketplace") { _ in removed }
        await server.on("plugin-management.updatePluginMarketplace") { _ in refreshed }
        let client = await plugins(server)

        let preview = try await client.addMarketplace(source: "/m", dryRun: true, operationId: nil, scope: .user)
        #expect(preview.marketplace?.id == "dry-run")
        let real = try await client.addMarketplace(source: "/m", dryRun: false, operationId: "op-2", scope: .workspace("/w"))
        #expect(real.marketplace?.id == "zcode-ios-probe-market")
        #expect(await server.calls(to: "plugin-management.addPluginMarketplace") == [
            .object(["workspacePath": .string(host), "source": .string("/m"), "dryRun": .bool(true)]),
            .object(["workspacePath": .string("/w"), "source": .string("/m"), "operationId": .string("op-2")]),
        ])

        #expect(try await client.removeMarketplace(id: "m", scope: .workspace("/w")).isEmpty)
        #expect(await server.calls(to: "plugin-management.removePluginMarketplace") == [.object([
            "workspacePath": .string("/w"), "marketplace": .string("m"),
        ])])

        let all = try await client.refreshMarketplace(id: nil, operationId: "op-3", scope: .user)
        #expect(all.marketplaces.count == 1)
        _ = try await client.refreshMarketplace(id: "m", operationId: "op-4", scope: .user)
        #expect(await server.calls(to: "plugin-management.updatePluginMarketplace") == [
            .object(["workspacePath": .string(host), "operationId": .string("op-3")]),
            .object(["workspacePath": .string(host), "marketplace": .string("m"), "operationId": .string("op-4")]),
        ])
    }

    @Test func retraitDeSourceRenvoieLesDiagnostics() async throws {
        let server = FakeZCodeServer()
        await server.on("plugin-management.removePluginMarketplace") { _ in
            .object(["diagnostics": .array([.object(["code": .string("c"), "message": .string("refus"), "severity": .string("error")])])])
        }
        let diagnostics = try await plugins(server).removeMarketplace(id: "m", scope: .user)
        #expect(diagnostics.count == 1 && diagnostics.first?.isError == true)
    }

    @Test func annulation() async throws {
        let server = FakeZCodeServer()
        let unknown = try record("plugins-lifecycle", "017")
        await server.on("plugin-management.cancelPluginOperation") { params in
            params["operationId"]?.stringValue == "op-1"
                ? .object(["operationId": .string("op-1"), "cancelled": .bool(true)]) : unknown
        }
        let client = await plugins(server)
        #expect(try await client.cancel(operationId: "op-1"))
        #expect(try await client.cancel(operationId: "zcode-probe-inexistante") == false)
        #expect(await server.calls(to: "plugin-management.cancelPluginOperation") == [
            .object(["operationId": .string("op-1")]),
            .object(["operationId": .string("zcode-probe-inexistante")]),
        ])
    }

    @Test func erreurDeLHoteTransmise() async throws {
        let server = FakeZCodeServer()
        await server.on("plugin-management.updatePlugin") { _ in throw FakeRemoteError("Plugin not found: x") }
        do {
            _ = try await plugins(server).update(pluginId: "x@m", scope: .user)
            Issue.record("la mise à jour aurait dû échouer")
        } catch let RPCError.remote(error) {
            #expect(error.message == "Plugin not found: x")
        }
    }

    @Test func reponseIllisible() async throws {
        let server = FakeZCodeServer()
        await server.on("plugin-management.getPluginsOverview") { _ in .string("?") }
        await server.on("plugin-management.uninstallPlugin") { _ in .string("?") }
        await server.on("plugin-management.cancelPluginOperation") { _ in .object([:]) }
        let client = await plugins(server)
        do {
            _ = try await client.overview(scope: .user)
            Issue.record("un aperçu illisible aurait dû échouer")
        } catch let AgentV4Error.malformedResponse(method, _) {
            #expect(method == "plugin-management.getPluginsOverview")
        }
        do {
            _ = try await client.uninstall(pluginId: "p@m", scope: .user)
            Issue.record("une réponse illisible aurait dû échouer")
        } catch let AgentV4Error.malformedResponse(method, _) {
            #expect(method == "plugin-management.uninstallPlugin")
        }
        do {
            _ = try await client.cancel(operationId: "op")
            Issue.record("une réponse sans `cancelled` aurait dû échouer")
        } catch let AgentV4Error.malformedResponse(method, _) {
            #expect(method == "plugin-management.cancelPluginOperation")
        }
    }
}
