import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// `PluginInfo` du plugin de sonde de la phase 0 (`plugins-lifecycle` 008) : une option sensible définie, une option
/// `label` valant « essai » par l'utilisateur.
private func probeInfo() throws -> PluginInfo {
    let list = try Fixtures.record(in: "v3.15.1/plugins-lifecycle", prefix: "008")
    let plugins = (list["plugins"]?.arrayValue ?? []).compactMap(PluginInfo.init(json:))
    return try #require(plugins.first { $0.id == "zcode-ios-probe@zcode-ios-probe-market" })
}

private func plugin(_ options: PluginConfigOption..., configured: [String: JSONValue] = [:],
                    sources: [String: String] = [:]) -> PluginInfo {
    PluginInfo(id: "p@m", name: "p", marketplace: "m", source: "cache", userConfig: options, configuredOptions: configured,
               optionSources: sources)
}

private func edited(_ form: PluginConfigForm, _ key: String, _ draft: PluginConfigForm.Draft?) -> PluginConfigForm {
    var form = form
    form.set(draft, for: key)
    return form
}

struct PluginConfigFormTests {
    @Test func formulaireDepuisLaConfigDeLHote() throws {
        let form = PluginConfigForm(scope: .user, plugin: try probeInfo())
        #expect(form.fields.map(\.id) == ["codeFactice", "label"])
        let label = try #require(form.fields.first { $0.id == "label" })
        #expect(label.currentText == "essai")
        #expect(label.isSet)
        #expect(label.source == "user")
        #expect(label.draft == nil)
        let secret = try #require(form.fields.first { $0.id == "codeFactice" })
        #expect(secret.currentText == "")
        #expect(secret.isSet)
        #expect(secret.source == "user")
    }

    @Test func valeurParDefautSiRienNEstEnregistre() {
        let form = PluginConfigForm(scope: .user, plugin: plugin(
            PluginConfigOption(key: "a", defaultValue: .string("x")),
            PluginConfigOption(key: "b", type: "number", defaultValue: .number(35)),
            PluginConfigOption(key: "c", type: "boolean", defaultValue: .bool(true)),
            PluginConfigOption(key: "d")))
        #expect(form.fields.map(\.currentText) == ["x", "35", "true", ""])
        #expect(form.fields.map(\.isSet) == [false, false, false, false])
        #expect(form.fields.map(\.source) == [nil, nil, nil, nil])
    }

    @Test func seulsLesChampsModifiesPartent() throws {
        let form = PluginConfigForm(scope: .user, plugin: try probeInfo())
        #expect(form.patch() == PluginConfigPatch(options: [:], clearKeys: []))
        let changed = edited(form, "label", .value("x"))
        #expect(changed.patch() == PluginConfigPatch(options: ["label": .string("x")], clearKeys: []))
        #expect(changed.issues().isEmpty)
    }

    @Test func secretVideInchange() throws {
        let form = edited(PluginConfigForm(scope: .user, plugin: try probeInfo()), "codeFactice", .value(""))
        #expect(form.patch() == PluginConfigPatch(options: [:], clearKeys: []))
        #expect(form.issues().isEmpty)
    }

    @Test func secretSaisiPart() throws {
        let form = edited(PluginConfigForm(scope: .user, plugin: try probeInfo()), "codeFactice", .value("x"))
        #expect(form.patch() == PluginConfigPatch(options: ["codeFactice": .string("x")], clearKeys: []))
    }

    @Test func effacerUneOption() throws {
        let form = edited(PluginConfigForm(scope: .user, plugin: try probeInfo()), "codeFactice", .clear)
        #expect(form.patch() == PluginConfigPatch(options: [:], clearKeys: ["codeFactice"]))
    }

    @Test func effacerEtModifierEnMemeTemps() throws {
        var form = PluginConfigForm(scope: .user, plugin: try probeInfo())
        form.set(.clear, for: "codeFactice")
        form.set(.value("y"), for: "label")
        #expect(form.patch() == PluginConfigPatch(options: ["label": .string("y")], clearKeys: ["codeFactice"]))
    }

    @Test func nombreAvecVirgule() {
        let base = PluginConfigForm(scope: .user, plugin: plugin(PluginConfigOption(key: "timeout", type: "number")))
        let valid = edited(base, "timeout", .value("2,5"))
        #expect(valid.patch() == PluginConfigPatch(options: ["timeout": .number(2.5)], clearKeys: []))
        #expect(valid.issues().isEmpty)
        #expect(edited(base, "timeout", .value("30")).patch().options == ["timeout": .number(30)])
        #expect(edited(base, "timeout", .value(" 2.5 ")).patch().options == ["timeout": .number(2.5)])

        let invalid = edited(base, "timeout", .value("deux"))
        #expect(invalid.issues() == ["timeout": "Nombre attendu."])
        #expect(invalid.patch() == PluginConfigPatch(options: [:], clearKeys: []))
        // Un nombre non fini n'est jamais envoyé.
        #expect(edited(base, "timeout", .value("inf")).issues() == ["timeout": "Nombre attendu."])
        #expect(edited(base, "timeout", .value("nan")).patch().options.isEmpty)
        // Vide : jamais un zéro silencieux, l'effacement se fait par « Effacer ».
        #expect(edited(base, "timeout", .value("")).issues() == ["timeout": "Nombre attendu."])
    }

    @Test func booleenEtAutresTypes() {
        let base = PluginConfigForm(scope: .user, plugin: plugin(
            PluginConfigOption(key: "on", type: "boolean"), PluginConfigOption(key: "dir", type: "directory")))
        var form = edited(base, "on", .toggle(false))
        form.set(.value("/tmp"), for: "dir")
        #expect(form.patch() == PluginConfigPatch(options: ["on": .bool(false), "dir": .string("/tmp")], clearKeys: []))
    }

    @Test func optionObligatoire() {
        // En portée Projet, pour que l'effacement de « ok » (défini par le projet) soit possible.
        let base = PluginConfigForm(scope: .workspace("/w"), plugin: plugin(
            PluginConfigOption(key: "token", required: true),
            PluginConfigOption(key: "ok", required: true, defaultValue: .string("v")),
            PluginConfigOption(key: "libre"), sources: ["ok": "workspace"]))
        #expect(base.issues() == ["token": "Obligatoire."])
        // Saisie : plus de défaut.
        #expect(edited(base, "token", .value("a")).issues().isEmpty)
        // Saisie vide ou effacement d'une option obligatoire.
        #expect(edited(base, "token", .value("")).issues() == ["token": "Obligatoire."])
        #expect(edited(base, "ok", .clear).issues()["ok"] == "Obligatoire.")
        #expect(edited(base, "ok", .value("")).issues()["ok"] == "Obligatoire.")
        // Une option facultative vide n'est pas une erreur.
        #expect(edited(base, "libre", .value("")).issues()["libre"] == nil)
    }

    @Test func optionObligatoireSensibleDejaDefinie() {
        let base = PluginConfigForm(scope: .user, plugin: plugin(
            PluginConfigOption(key: "s", required: true, sensitive: true), sources: ["s": "user"]))
        #expect(base.issues().isEmpty)
        // Vide = inchangé : la valeur de l'hôte reste.
        #expect(edited(base, "s", .value("")).issues().isEmpty)
        #expect(edited(base, "s", .clear).issues() == ["s": "Obligatoire."])
        let unset = PluginConfigForm(scope: .user, plugin: plugin(PluginConfigOption(key: "s", required: true, sensitive: true)))
        #expect(unset.issues() == ["s": "Obligatoire."])
        #expect(edited(unset, "s", .value("")).issues() == ["s": "Obligatoire."])
    }

    @Test func optionSensibleJamaisRelue() {
        let info = plugin(
            PluginConfigOption(key: "s", sensitive: true, defaultValue: .string("d")),
            configured: ["s": .string("v")], sources: ["s": "workspace"])
        let form = PluginConfigForm(scope: .user, plugin: info)
        #expect(form.fields.map(\.currentText) == [""])
        #expect(form.fields.first?.isSet == true)
        #expect(form.fields.first?.source == "workspace")
    }

    @Test func titreRepliSurLaCle() {
        let form = PluginConfigForm(scope: .user, plugin: plugin(
            PluginConfigOption(key: "a", title: "Titre"), PluginConfigOption(key: "b", title: ""),
            PluginConfigOption(key: "c", description: "")))
        #expect(form.fields.map(\.title) == ["Titre", "b", "c"])
        #expect(form.fields.map(\.hint) == [nil, nil, nil])
    }

    @Test func effacerUnBrouillon() throws {
        var form = edited(PluginConfigForm(scope: .user, plugin: try probeInfo()), "label", .value("x"))
        form.set(nil, for: "label")
        #expect(form.patch() == PluginConfigPatch(options: [:], clearKeys: []))
        form.set(.value("x"), for: "inconnue")                                // clé inconnue : sans effet
        #expect(form.patch().options.isEmpty)
    }

    /// Règle de ZCode Web (`PluginConfigControls.tsx`) : « Effacer » seulement si la valeur est définie dans la portée de
    /// l'écran, et pour une option sensible ou en portée Projet. Ailleurs, `clearOptionKeys` ne ferait rien sur l'hôte.
    @Test func effacerSelonLaPortee() throws {
        func canClear(_ scope: ExtensionScope, source: String?, sensitive: Bool) throws -> Bool {
            let sources = source.map { ["k": $0] } ?? [:]
            let form = PluginConfigForm(scope: scope, plugin: plugin(PluginConfigOption(key: "k", sensitive: sensitive), sources: sources))
            return try #require(form.fields.first).canClear
        }
        let project = ExtensionScope.workspace("/w")
        #expect(try canClear(.user, source: "user", sensitive: true))
        #expect(try !canClear(.user, source: "user", sensitive: false))           // valeur ordinaire de l'utilisateur
        #expect(try canClear(project, source: "workspace", sensitive: false))
        #expect(try canClear(project, source: "workspace", sensitive: true))
        #expect(try !canClear(project, source: "user", sensitive: true))          // définie pour l'utilisateur, pas le projet
        #expect(try !canClear(project, source: "user", sensitive: false))
        #expect(try !canClear(.user, source: "workspace", sensitive: true))
        #expect(try !canClear(.user, source: nil, sensitive: true))               // rien d'enregistré
        #expect(try !canClear(project, source: nil, sensitive: false))
    }

    @Test func effacementImpossibleIgnore() throws {
        // Projet, option sensible définie pour l'utilisateur : rien à effacer dans le projet.
        var form = PluginConfigForm(scope: .workspace("/w"), plugin: try probeInfo())
        form.set(.clear, for: "codeFactice")
        #expect(form.fields.first { $0.id == "codeFactice" }?.draft == nil)
        let index = try #require(form.fields.firstIndex { $0.id == "codeFactice" })
        form.fields[index].draft = .clear                                          // liaison directe de la vue
        #expect(form.fields[index].draft == nil)
        #expect(form.patch() == PluginConfigPatch(options: [:], clearKeys: []))
        // Un brouillon permis reste possible.
        form.fields[index].draft = .value("x")
        #expect(form.patch() == PluginConfigPatch(options: ["codeFactice": .string("x")], clearKeys: []))
    }
}
