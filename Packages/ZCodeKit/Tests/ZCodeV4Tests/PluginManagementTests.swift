import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

struct PluginManagementTests {
    private let probeId = "zcode-ios-probe@zcode-ios-probe-market"

    private func record(_ folder: String, _ prefix: String) throws -> JSONValue {
        try Fixtures.record(in: "v3.15.1/\(folder)", prefix: prefix)
    }

    // MARK: - Enregistrements réels

    @Test func apercuReel() throws {
        let overview = try PluginsOverview(json: try record("plugins-read", "001"))
        #expect(overview.supported && overview.unsupportedReason == nil)
        let official = try #require(overview.marketplaces.first { $0.id == "zcode-plugins-official" })
        #expect(official.isOfficial && official.pluginCount > 0)
        #expect(official.sourceKind == "url" && official.sourceLabel == "https://cdn-zcode.z.ai/zcode/official-plugin/marketplace.json")
        #expect(official.lastUpdated != nil)
        let github = try #require(overview.marketplaces.first { $0.id == "claude-plugins-official" })
        #expect(github.sourceKind == "github" && github.sourceLabel == "anthropics/claude-plugins-official")
        #expect(github.lastUpdated == nil && github.refreshFailure == nil)
        #expect(!overview.availablePlugins.isEmpty)
        for plugin in overview.installedPlugins {
            #expect(plugin.id == "\(plugin.name)@\(plugin.marketplace)")
        }
        #expect(overview.restorableBuiltins.isEmpty && overview.diagnostics.isEmpty)
    }

    @Test func catalogueEtInstallesReels() throws {
        let overview = try PluginsOverview(json: try record("plugins-read", "001"))
        let cloudbase = try #require(overview.availablePlugins.first { $0.id == "cloudbase-skills@zcode-plugins-official" })
        #expect(!cloudbase.installed && cloudbase.version == "0.1.0" && cloudbase.componentTypes.isEmpty)
        #expect(cloudbase.listing?.category == "developer-tools" && cloudbase.listing?.author == "TencentCloudBase")
        #expect(cloudbase.listing?.descriptionI18n["en"] != nil && cloudbase.listing?.requiresPaidPlan == false)
        let github = try #require(overview.installedPlugins.first { $0.id == "github@zcode-plugins-official" })
        #expect(github.enabled && github.scope == "user" && github.updateStatus == .none)
        #expect(github.componentTypes == [.skill] && github.latestVersion == "0.1.2" && github.installedAt != nil)
    }

    @Test func pluginJetableDecrit() throws {
        let description = try PluginDescription(json: try record("plugins-lifecycle", "004"))
        let skills = try #require(description.components.first { $0.kind == .skill })
        #expect(skills.items.contains { $0.name == "zcode-ios-probe" })
        #expect(skills.items.first?.description == "Skill jetable de zcode-probe")
        #expect(description.version == "1.0.0" && description.author == nil && description.homepage == nil)
        #expect(description.diagnostics.isEmpty && !description.failed)
    }

    @Test func descriptionDUnPluginOfficiel() throws {
        let description = try PluginDescription(json: try record("plugins-read", "004"))
        #expect(description.components.contains { $0.kind == .skill && $0.items.count > 1 })
        #expect(!description.failed)
    }

    @Test func installationReelle() throws {
        let result = try PluginInstallResult(json: try record("plugins-lifecycle", "005"))
        #expect(result.failure == nil && result.diagnostics.isEmpty)
        let installed = try #require(result.installedPlugins.first { $0.id == probeId })
        // Le résultat d'une installation ne porte ni composants, ni fiche, ni état de mise à jour.
        #expect(installed.name == "zcode-ios-probe" && installed.marketplace == "zcode-ios-probe-market")
        #expect(installed.enabled && installed.scope == "user" && installed.version == "1.0.0")
        #expect(installed.componentTypes.isEmpty && installed.listing == nil && installed.updateStatus == .none)
    }

    @Test func optionSensibleAbsente() throws {
        let list = try PluginsList(json: try record("plugins-lifecycle", "008"))
        let probe = try #require(list.plugins.first { $0.id == probeId })
        let secret = try #require(probe.userConfig.first { $0.key == "codeFactice" })
        #expect(secret.sensitive && !secret.required && secret.type == "string" && secret.title == "Code factice")
        #expect(probe.userConfig.map(\.key) == ["codeFactice", "label"])
        let label = try #require(probe.userConfig.first { $0.key == "label" })
        #expect(!label.sensitive && label.defaultValue == .string("sonde"))
        #expect(probe.configuredOptions["label"] == .string("essai"))
        #expect(probe.configuredOptions["codeFactice"] == nil)
        #expect(probe.optionSources.keys.sorted() == ["codeFactice", "label"])
        #expect(probe.source == "cache" && probe.enabledSource == "user" && !probe.packageMissing)
    }

    @Test func listeReelleDesPluginsOfficiels() throws {
        let list = try PluginsList(json: try record("plugins-read", "003"))
        #expect(list.plugins.count == 16)
        let visualize = try #require(list.plugins.first { $0.id == "visualize@zcode-plugins-official" })
        #expect(visualize.source == "official" && visualize.author == "ZCode" && visualize.enabled)
        #expect(visualize.components.first?.kind == .skill && visualize.hookDetails.isEmpty)
        #expect(visualize.mcpServerNames.isEmpty && visualize.userConfig.isEmpty && visualize.configuredOptions.isEmpty)
    }

    @Test func activationParPortee() throws {
        let projet = try PluginsOverview(json: try record("plugins-lifecycle", "010"))
        let utilisateur = try PluginsOverview(json: try record("plugins-lifecycle", "011"))
        #expect(try #require(projet.installedPlugins.first { $0.id == probeId }).enabled == false)
        #expect(try #require(utilisateur.installedPlugins.first { $0.id == probeId }).enabled == true)
    }

    @Test func activationRenvoieLaFiche() throws {
        // `setPluginEnabled` renvoie `{plugin, enabled}` : la fiche se décode comme celle de `listPlugins`.
        let value = try record("plugins-lifecycle", "009")
        let info = try #require(value["plugin"].flatMap(PluginInfo.init(json:)))
        #expect(!info.enabled && info.enabledSource == "workspace")
        #expect(info.configuredOptions == ["label": .string("essai")])
    }

    @Test func installationAvecDiagnostic() throws {
        let result = try PluginInstallResult(json: try record("plugins-lifecycle", "016"))
        #expect(result.installedPlugins.isEmpty)
        #expect(result.failure?.isError == true)
        #expect(result.failure?.code == "plugin_dependency_missing")
        #expect(result.failure?.pluginId == "absent@zcode-ios-probe-market")
    }

    @Test func sourceAjouteeEtActualisee() throws {
        let dryRun = try MarketplaceMutationResult(json: try record("plugins-lifecycle", "001"))
        #expect(dryRun.marketplace?.id == "dry-run" && dryRun.marketplace?.sourceKind == "directory")
        #expect(dryRun.marketplace?.sourceLabel == "/Users/me/claude/.zcode-check/marketplace")
        #expect(dryRun.marketplaces.isEmpty && dryRun.failure == nil)
        let added = try MarketplaceMutationResult(json: try record("plugins-lifecycle", "002"))
        #expect(added.marketplace?.id == "zcode-ios-probe-market" && added.marketplace?.pluginCount == 1)
        #expect(added.marketplace?.description == "Marketplace jetable de zcode-probe" && !(added.marketplace?.isOfficial ?? true))
        let refreshed = try MarketplaceMutationResult(json: try record("plugins-lifecycle", "014"))
        #expect(refreshed.marketplace == nil && refreshed.marketplaces.map(\.id) == ["zcode-ios-probe-market"])
    }

    // MARK: - Cas synthétiques

    @Test func decodageTolerant() throws {
        let overview = try PluginsOverview(json: .object([
            "marketplaces": .array([
                .object(["id": .string("m"), "name": .string("m"), "futur": .bool(true)]),
                .object(["name": .string("sans-id")]),
            ]),
            "availablePlugins": .array([
                .object([
                    "id": .string("a@m"), "name": .string("a"), "marketplace": .string("m"), "installed": .bool(false),
                    "componentTypes": .array([.string("widget"), .string("skill")]),
                ]),
                .object(["name": .string("sans-id"), "marketplace": .string("m")]),
            ]),
            "installedPlugins": .array([
                .object([
                    "id": .string("b@m"), "name": .string("b"), "marketplace": .string("m"), "enabled": .bool(true),
                    "scope": .string("user"), "updateStatus": .string("quantique"),
                ]),
                .object(["name": .string("sans-id")]),
            ]),
            "futur": .string("ignoré"),
        ]))
        #expect(overview.marketplaces.map(\.id) == ["m"])
        #expect(overview.marketplaces.first?.pluginCount == 0 && overview.marketplaces.first?.sourceKind == nil)
        #expect(overview.availablePlugins.map(\.id) == ["a@m"])
        #expect(overview.availablePlugins.first?.componentTypes == [PluginComponentKind(rawValue: "widget"), .skill])
        #expect(overview.installedPlugins.map(\.id) == ["b@m"])
        #expect(overview.installedPlugins.first?.updateStatus == PluginUpdateStatus(rawValue: "quantique"))
        #expect(overview.supported && overview.diagnostics.isEmpty && overview.restorableBuiltins.isEmpty)
        #expect(throws: V4DecodingError.invalid("plugin-management.getPluginsOverview")) {
            try PluginsOverview(json: .string("?"))
        }
        #expect(throws: V4DecodingError.invalid("plugin-management.listPlugins")) { try PluginsList(json: .null) }
        #expect(throws: V4DecodingError.invalid("plugin-management.describePlugin")) { try PluginDescription(json: .null) }
        #expect(throws: V4DecodingError.invalid("plugin-management.installPlugin")) { try PluginInstallResult(json: .null) }
        #expect(throws: V4DecodingError.invalid("plugin-management.addPluginMarketplace")) {
            try MarketplaceMutationResult(json: .null)
        }
    }

    @Test func composantsInconnusGardesBruts() throws {
        let description = try PluginDescription(json: .object([
            "components": .array([
                .object(["kind": .string("widget"), "items": .array([.object(["name": .string("w")]), .object([:])])]),
                .object(["items": .array([])]),
            ]),
        ]))
        #expect(description.components.count == 1)
        #expect(description.components.first?.kind == PluginComponentKind(rawValue: "widget"))
        #expect(description.components.first?.items == [.init(name: "w", description: nil)])
    }

    @Test func capaciteEtEchecDeMarketplace() throws {
        let overview = try PluginsOverview(json: .object([
            "capability": .object(["supported": .bool(false), "reason": .string("indisponible")]),
            "restorableBuiltins": .array([
                .object(["id": .string("x@m"), "name": .string("x"), "marketplace": .string("m"), "installed": .bool(false)]),
            ]),
            "marketplaces": .array([
                .object([
                    "id": .string("m"), "name": .string("m"), "pluginCount": .number(3),
                    "lastUpdated": .string("2026-10-17T05:20:36Z"),
                    "refreshFailure": .object(["code": .string("c"), "failedAt": .string("t"), "message": .string("réseau coupé")]),
                ]),
            ]),
        ]))
        #expect(!overview.supported && overview.unsupportedReason == "indisponible")
        #expect(overview.restorableBuiltins.map(\.id) == ["x@m"])
        #expect(overview.marketplaces.first?.refreshFailure == "réseau coupé")
        #expect(overview.marketplaces.first?.lastUpdated == Date(timeIntervalSince1970: 1_792_214_436))
    }

    @Test func enTetesJamaisDecodes() throws {
        let json = JSONValue.object([
            "id": .string("m"), "name": .string("m"), "pluginCount": .number(0),
            "source": .object([
                "source": .string("url"), "url": .string("https://x/m.json"),
                "headers": .object(["Authorization": .string("secret")]),
            ]),
        ])
        let summary = try #require(MarketplaceSummary(json: json))
        #expect(summary.sourceKind == "url" && summary.sourceLabel == "https://x/m.json")
        #expect(!String(describing: summary).contains("secret"))
        #expect(!String(reflecting: summary).contains("secret"))
        #expect(!String(describing: summary).contains("Authorization"))
    }

    @Test func libelleDeSource() throws {
        func label(_ source: [String: JSONValue]) -> String? {
            MarketplaceSummary(json: .object(["id": .string("m"), "name": .string("m"), "source": .object(source)]))?.sourceLabel
        }
        #expect(label(["source": .string("github"), "repo": .string("o/r")]) == "o/r")
        #expect(label(["source": .string("directory"), "path": .string("/p")]) == "/p")
        #expect(label(["source": .string("git"), "url": .string("git@h:o/r.git")]) == "git@h:o/r.git")
        #expect(label(["source": .string("inconnue")]) == nil)
    }

    @Test func optionSensibleRetireeMemeEnvoyee() throws {
        let info = try #require(PluginInfo(json: .object([
            "id": .string("p@m"), "name": .string("p"), "marketplace": .string("m"), "source": .string("cache"),
            "enabled": .bool(true),
            "userConfig": .object([
                "code": .object(["sensitive": .bool(true), "type": .string("string")]),
                "nombre": .object(["type": .string("number"), "default": .number(3), "required": .bool(true)]),
                "bizarre": .object(["type": .string("hologramme")]),
                "dossier": .object(["type": .string("directory")]),
            ]),
            "configuredOptions": .object(["code": .string("valeur"), "nombre": .number(5), "actif": .bool(true)]),
            "optionSources": .object(["code": .string("user"), "nombre": .string("workspace")]),
        ])))
        #expect(info.configuredOptions == ["nombre": .number(5), "actif": .bool(true)])
        #expect(!String(describing: info).contains("valeur"))
        #expect(info.userConfig.map(\.key) == ["bizarre", "code", "dossier", "nombre"])
        #expect(info.userConfig.map(\.type) == ["string", "string", "directory", "number"])
        #expect(info.userConfig.first { $0.key == "nombre" }?.required == true)
        #expect(info.userConfig.first { $0.key == "nombre" }?.defaultValue == .number(3))
        #expect(info.optionSources == ["code": "user", "nombre": "workspace"])
    }

    @Test func detailDUnPluginSelonLesSources() throws {
        let info = try #require(PluginInfo(json: .object([
            "id": .string("p@m"), "name": .string("p"), "marketplace": .string("m"), "source": .string("cache"),
            "enabled": .bool(false), "enabledSource": .string("workspace"), "packageStatus": .string("missing"),
            "author": .string("A"), "homepage": .string("https://h"), "description": .string("d"), "version": .string("2"),
            "mcpServerNames": .array([.string("srv")]),
            "hookDetails": .array([
                .object([
                    "event": .string("PreToolUse"), "matcher": .string("Bash"), "type": .string("command"),
                    "command": .string("./check.sh"), "sourcePath": .string("/x"), "runnable": .bool(true),
                ]),
                .object(["event": .string("Stop")]),
            ]),
        ])))
        #expect(info.packageMissing && info.enabledSource == "workspace" && info.mcpServerNames == ["srv"])
        #expect(info.author == "A" && info.homepage == "https://h" && info.description == "d" && info.version == "2")
        #expect(info.hookDetails == [PluginHookDetail(event: "PreToolUse", command: "./check.sh", matcher: "Bash", runnable: true)])
    }

    @Test func descriptionEnEchec() throws {
        let failed = try PluginDescription(json: .object([
            "components": .array([]),
            "diagnostics": .array([.object(["code": .string("c"), "message": .string("m"), "severity": .string("error")])]),
            "metadata": .object(["author": .string("A"), "homepage": .string("https://h"), "version": .string("1")]),
        ]))
        #expect(failed.failed && failed.author == "A" && failed.homepage == "https://h" && failed.version == "1")
        let warning = try PluginDescription(json: .object([
            "components": .array([]),
            "diagnostics": .array([.object(["code": .string("c"), "message": .string("m"), "severity": .string("warning")])]),
        ]))
        #expect(!warning.failed)
    }

    @Test func diagnosticsEtGravite() {
        let error = PluginDiagnostic(json: .object(["code": .string("c"), "message": .string("m"), "severity": .string("error")]))
        #expect(error?.isError == true)
        let warning = PluginDiagnostic(json: .object(["code": .string("c"), "message": .string("m"), "severity": .string("warning")]))
        #expect(warning?.isError == false)
        let none = PluginDiagnostic(json: .object(["code": .string("c"), "message": .string("m")]))
        #expect(none?.isError == false && none?.severity == nil)
        #expect(PluginDiagnostic(json: .object([:])) == nil)
        #expect(PluginDiagnostic.list(.array([.string("?"), .object(["message": .string("m")])])).count == 1)
        #expect(PluginDiagnostic.list(nil).isEmpty)
    }

    @Test func mutationEnEchecEtDatesSansFraction() throws {
        let result = try MarketplaceMutationResult(json: .object([
            "marketplace": .object(["id": .string("m"), "name": .string("m"), "lastUpdated": .string("2026-10-17T05:20:36Z")]),
            "diagnostics": .array([
                .object(["code": .string("w"), "message": .string("avertissement"), "severity": .string("warning")]),
                .object(["code": .string("e"), "message": .string("refus"), "severity": .string("error")]),
            ]),
        ]))
        #expect(result.failure?.code == "e")
        #expect(result.marketplace?.lastUpdated != nil)
        let withFraction = MarketplaceSummary(json: .object([
            "id": .string("m"), "name": .string("m"), "lastUpdated": .string("2026-10-17T05:20:36.506Z"),
        ]))
        #expect(withFraction?.lastUpdated != nil)
    }
}
