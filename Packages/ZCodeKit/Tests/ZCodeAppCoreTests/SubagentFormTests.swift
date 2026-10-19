import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Agent synthétique : seuls les champs utiles aux formulaires.
private func agent(
    _ name: String, scope: String = "user", tools: [String]? = nil, extra: [String: JSONValue] = [:]
) throws -> AgentSummary {
    var object: [String: JSONValue] = [
        "id": .string("user:\(scope):\(name.lowercased())"), "name": .string(name), "path": .string("/h/\(name).md"),
        "description": .string("d"), "systemPrompt": .string("s"), "scope": .string(scope), "source": .string("user"),
    ]
    if let tools { object["tools"] = .array(tools.map(JSONValue.string)) }
    for (key, value) in extra { object[key] = value }
    return try #require(AgentSummary(json: .object(object)))
}

/// Catalogue minimal : un fournisseur, un modèle actif aux niveaux donnés, un modèle désactivé.
private func catalog(levels: [String] = ["low", "medium", "high"]) throws -> ModelSelectionView {
    func model(_ id: String, enabled: Bool, levels: [String]) -> JSONValue {
        .object(["modelId": .string(id), "config": .object([
            "enabled": .bool(enabled),
            "optionSpecs": .object(["reasoningLevel": .object(["values": .array(levels.map(JSONValue.string))])]),
        ])])
    }
    return try ModelSelectionView(json: .object([
        "revision": .number(1),
        "providers": .array([.object([
            "providerId": .string("glm"), "providerName": .string("GLM"),
            "models": .array([model("on", enabled: true, levels: levels), model("off", enabled: false, levels: levels)]),
        ])]),
    ]))
}

/// Formulaire valide, que chaque test dégrade d'un seul champ.
private func validForm() -> SubagentForm {
    var form = SubagentForm(scope: .user)
    form.name = "revue-code"
    form.description = "Relit le code"
    form.systemPrompt = "Relis le code."
    return form
}

private func issues(_ form: SubagentForm, existing: [AgentSummary] = [], editing: AgentSummary? = nil,
                    catalog: ModelSelectionView? = nil) -> [SubagentFormIssue] {
    form.issues(existing: existing, editing: editing, catalog: catalog)
}

struct SubagentFormTests {
    @Test func valeursParDefaut() {
        let form = SubagentForm(scope: .workspace("/w"))
        #expect(form.scope == .workspace("/w"))
        #expect(form.color == .yellow && form.injectAgentsMd && form.allTools)
        #expect(form.modelSelection == nil && form.selectedTools.isEmpty && form.extraTools.isEmpty)
        #expect(SubagentForm.knownTools == ["Read", "Grep", "Glob", "Bash", "Edit", "Write", "WebFetch", "WebSearch", "TodoWrite"])
        #expect(SubagentForm.riskyTools == ["Bash", "Edit", "Write"])
        #expect(issues(validForm()).isEmpty)
    }

    @Test func validationCommeLeWeb() {
        let cases: [(String, SubagentFormIssue)] = [
            ("ab", .nameLength), ("", .nameLength), (String(repeating: "a", count: 51), .nameLength),
            ("a b c", .nameCharacters), ("éclair", .nameCharacters), ("a_b", .nameCharacters),
            ("Explore", .nameReserved), ("general-purpose", .nameReserved),
        ]
        for (name, expected) in cases {
            var form = validForm()
            form.name = name
            #expect(issues(form) == [expected], "\(name)")
        }
        for name in ["explore", "abc", String(repeating: "a", count: 50), "Mon-Agent-2"] {
            var form = validForm()
            form.name = name
            #expect(issues(form).isEmpty, "\(name)")
        }
        var spaced = validForm()
        spaced.name = "  revue  "                                            // valeurs prises après `trim`
        #expect(issues(spaced).isEmpty)
        var description = validForm()
        description.description = "  "
        #expect(issues(description) == [.descriptionMissing])
        var prompt = validForm()
        prompt.systemPrompt = ""
        #expect(issues(prompt) == [.systemPromptMissing])
    }

    @Test func nomDejaPrisDansLaPortee() throws {
        let existing = [try agent("Revue"), try agent("Autre")]
        var form = validForm()
        form.name = "revue"
        #expect(issues(form, existing: existing) == [.nameTaken])
        #expect(issues(form, existing: existing, editing: existing[0]).isEmpty)
        form.name = "autre"                                                  // en éditant « Revue », « Autre » reste pris
        #expect(issues(form, existing: existing, editing: existing[0]) == [.nameTaken])
    }

    @Test func modeleEtEffort() throws {
        let view = try catalog()
        var form = validForm()
        let model = try #require(view.model(providerId: "glm", modelId: "on"))
        form.selectModel(providerId: "glm", model: model)
        #expect(form.modelSelection == ModelSelection(providerId: "glm", modelId: "on", reasoningLevel: "high"))
        #expect(issues(form, catalog: view).isEmpty)

        let none = try catalog(levels: [])
        form.selectModel(providerId: "glm", model: try #require(none.model(providerId: "glm", modelId: "on")))
        #expect(form.modelSelection?.options == nil)
        #expect(issues(form, catalog: none).isEmpty)

        var disabled = validForm()
        disabled.selectModel(providerId: "glm", model: try #require(view.model(providerId: "glm", modelId: "off")))
        #expect(issues(disabled, catalog: view) == [.modelUnavailable])

        var missing = validForm()
        missing.modelSelection = ModelSelection(providerId: "glm", modelId: "retiré", reasoningLevel: "high")
        #expect(issues(missing, catalog: view) == [.modelUnavailable])

        var effort = validForm()
        effort.modelSelection = ModelSelection(providerId: "glm", modelId: "on", reasoningLevel: "max")
        #expect(issues(effort, catalog: view) == [.effortUnsupported])
        // Catalogue pas encore chargé : aucun de ces deux défauts.
        #expect(issues(effort, catalog: nil).isEmpty)
        #expect(issues(disabled, catalog: nil).isEmpty)
    }

    @Test func outilsInconnusConserves() throws {
        let source = try agent("outils", tools: ["Read", "Bash(git diff *)", "mcp__github__create_issue"])
        let form = SubagentForm(editing: source, scope: .user)
        #expect(!form.allTools)
        #expect(form.selectedTools == ["Read"])
        #expect(form.extraTools == ["Bash(git diff *)", "mcp__github__create_issue"])
        #expect(form.config(basedOn: source).tools == ["Read", "Bash(git diff *)", "mcp__github__create_issue"])
        #expect(issues(form).isEmpty)
    }

    @Test func outilsCochesDansLOrdreDuWeb() throws {
        var form = validForm()
        form.allTools = false
        form.selectedTools = ["Write", "Read", "Glob"]
        form.extraTools = ["perso"]
        #expect(form.config(basedOn: nil).tools == ["Read", "Glob", "Write", "perso"])
    }

    @Test func etoileGardeeTelleQuelle() throws {
        for original in [["*"], []] as [[String]] {
            let source = try agent("etoile", tools: original)
            let form = SubagentForm(editing: source, scope: .user)
            #expect(form.allTools)
            #expect(form.config(basedOn: source).tools == original)
        }
        let all = try agent("tous")                                          // `tools` absent
        #expect(SubagentForm(editing: all, scope: .user).allTools)
        #expect(SubagentForm(editing: all, scope: .user).config(basedOn: all).json.objectValue?["tools"] == nil)
    }

    @Test func toutDecocheOuListeLimiteeRedevientTous() throws {
        // Repasser à « Tous les outils » sur une liste limitée : la clé disparaît, elle ne devient pas `["*"]`.
        let source = try agent("limite", tools: ["Read"])
        var form = SubagentForm(editing: source, scope: .user)
        form.allTools = true
        #expect(form.config(basedOn: source).tools == nil)
    }

    @Test func tousLesOutilsOmis() {
        let json = SubagentForm(scope: .user).config(basedOn: nil).json
        #expect(json.objectValue?["tools"] == nil)
    }

    @Test func aucunOutilCoche() {
        var form = validForm()
        form.allTools = false
        #expect(issues(form) == [.toolsEmpty])
        form.extraTools = ["mcp__x"]                                         // une entrée inconnue compte
        #expect(issues(form).isEmpty)
        form.extraTools = []
        form.selectedTools = ["Read"]
        #expect(issues(form).isEmpty)
    }

    @Test func configurationDeCreation() {
        var form = validForm()
        form.name = "  revue-code "
        form.systemPrompt = "\nRelis le code.\n"
        let config = form.config(basedOn: nil)
        #expect(config.json == .object([
            "name": .string("revue-code"), "description": .string("Relit le code"),
            "systemPrompt": .string("Relis le code."), "color": .string("yellow"), "injectAgentsMd": .bool(true),
        ]))
    }

    @Test func editionReprendLesChampsNonEdites() throws {
        // Données canoniques : la tâche des champs avancés ne doit pas les modifier (outils connus dans l'ordre du web,
        // compétences sans doublon ni espace, `maxTurns` > 0).
        let source = try agent("avance", tools: ["Read"], extra: [
            "skills": .array([.string("pdf"), .string("docx")]),
            "permissionMode": .string("acceptEdits"),
            "maxTurns": .number(12),
            "background": .bool(true),
            "disallowedTools": .array([.string("Grep"), .string("Bash"), .string("Write"), .string("mcp__x__y")]),
            "mcpServers": .array([.object(["name": .string("github"), "command": .string("gh")])]),
        ])
        var form = SubagentForm(editing: source, scope: .user)
        form.name = "avance-2"
        form.color = .pink
        let config = form.config(basedOn: source)
        #expect(config.name == "avance-2" && config.color == .pink)
        #expect(config.skills == ["pdf", "docx"])
        #expect(config.permissionMode == AgentPermissionMode(rawValue: "acceptEdits"))
        #expect(config.maxTurns == 12)
        #expect(config.background == true)
        #expect(config.disallowedTools == ["Grep", "Bash", "Write", "mcp__x__y"])
        #expect(config.mcpServers == source.mcpServers)
    }

    @Test func editionRelitLesReglages() throws {
        let selection = ModelSelection(providerId: "glm", modelId: "on", reasoningLevel: "low")
        let source = try agent("regle", extra: [
            "color": .string("pink"), "injectAgentsMd": .bool(false), "description": .string("Quoi"),
            "systemPrompt": .string("Fais."), "modelSelection": try V4JSON.encode(selection),
        ])
        let form = SubagentForm(editing: source, scope: .workspace("/w"))
        #expect(form.name == "regle" && form.description == "Quoi" && form.systemPrompt == "Fais.")
        #expect(form.color == .pink && !form.injectAgentsMd && form.modelSelection == selection)
        #expect(form.scope == .workspace("/w"))
        let config = form.config(basedOn: source)
        #expect(config.injectAgentsMd == false && config.modelSelection == selection)
        // Sans réglage lu : défauts du web (jaune, AGENTS.md joint).
        let bare = SubagentForm(editing: try agent("nu"), scope: .user)
        #expect(bare.color == .yellow && bare.injectAgentsMd)
    }

    // MARK: - Champs avancés

    @Test func champsAvancesEnvoyes() throws {
        var form = validForm()
        form.disallowedTools = ["Bash"]
        form.skillsText = "a, b\nb"
        form.maxTurnsText = "12"
        form.background = true
        let object = try #require(form.config(basedOn: nil).json.objectValue)
        #expect(object["disallowedTools"] == .array([.string("Bash")]))
        #expect(object["skills"] == .array([.string("a"), .string("b")]))
        #expect(object["maxTurns"] == .number(12))
        #expect(object["background"] == .bool(true))
        #expect(issues(form).isEmpty)
    }

    @Test func champsAvancesVidesOmis() throws {
        var form = validForm()
        form.skillsText = " , \n  "
        form.maxTurnsText = "  "
        let object = try #require(form.config(basedOn: nil).json.objectValue)
        for key in ["disallowedTools", "skills", "maxTurns", "background", "permissionMode", "mcpServers"] {
            #expect(object[key] == nil, "\(key)")
        }
        #expect(issues(form).isEmpty)
    }

    @Test func outilsInterditsConnusPuisInconnus() throws {
        let source = try agent("interdits", extra: [
            "disallowedTools": .array([.string("mcp__x__y"), .string("Write"), .string("Bash(rm *)"), .string("Grep")]),
        ])
        var form = SubagentForm(editing: source, scope: .user)
        #expect(form.disallowedTools == ["Write", "Grep"])
        #expect(form.extraDisallowedTools == ["mcp__x__y", "Bash(rm *)"])
        #expect(form.config(basedOn: source).disallowedTools == ["Grep", "Write", "mcp__x__y", "Bash(rm *)"])
        form.disallowedTools = []
        form.extraDisallowedTools = []
        #expect(form.config(basedOn: source).disallowedTools == nil)
    }

    @Test func toursMaxInvalides() throws {
        for text in ["0", "-3", "douze", "1.5", "99999999999999999999"] {
            var form = validForm()
            form.maxTurnsText = text
            #expect(issues(form) == [.maxTurnsInvalid], "\(text)")
        }
        for text in ["", "  ", "1", " 40 "] {
            var form = validForm()
            form.maxTurnsText = text
            #expect(issues(form).isEmpty, "\(text)")
        }
        var form = validForm()
        form.maxTurnsText = " 40 "
        #expect(form.config(basedOn: nil).maxTurns == 40)
        form.maxTurnsText = ""
        #expect(form.config(basedOn: nil).json.objectValue?["maxTurns"] == nil)
        #expect(SubagentFormIssue.maxTurnsInvalid.message == "Nombre de tours : entier supérieur à zéro.")
    }

    @Test func arrierePlanRemisAbsent() throws {
        // Sans clé d'origine : coché puis décoché, aucune clé.
        let source = try agent("sans")
        var form = SubagentForm(editing: source, scope: .user)
        #expect(!form.background)
        form.background = true
        #expect(form.config(basedOn: source).background == true)
        form.background = false
        #expect(form.config(basedOn: source).json.objectValue?["background"] == nil)
        #expect(validForm().config(basedOn: nil).json.objectValue?["background"] == nil)
        // Avec la clé d'origine : décocher l'écrit `false`.
        let had = try agent("avec", extra: ["background": .bool(true)])
        var edited = SubagentForm(editing: had, scope: .user)
        #expect(edited.background)
        edited.background = false
        #expect(edited.config(basedOn: had).background == false)
        let explicitFalse = try agent("faux", extra: ["background": .bool(false)])
        #expect(SubagentForm(editing: explicitFalse, scope: .user).config(basedOn: explicitFalse).background == false)
    }

    @Test func modeDAutorisationSeulementUtilisateur() throws {
        let source = try agent("mode", scope: "workspace", extra: ["permissionMode": .string("plan")])
        var project = SubagentForm(editing: source, scope: .workspace("/w"))
        #expect(!project.permissionModeEditable)
        project.permissionMode = .auto
        #expect(project.config(basedOn: source).permissionMode == AgentPermissionMode(rawValue: "plan"))
        var created = SubagentForm(scope: .workspace("/w"))
        created.permissionMode = .auto
        #expect(created.config(basedOn: nil).json.objectValue?["permissionMode"] == nil)

        let own = try agent("mode", extra: ["permissionMode": .string("plan")])
        var user = SubagentForm(editing: own, scope: .user)
        #expect(user.permissionModeEditable)
        #expect(user.permissionMode == .plan)
        user.permissionMode = .auto
        #expect(user.config(basedOn: own).permissionMode == .auto)
        user.permissionMode = nil                                            // « Défaut » : la clé disparaît
        #expect(user.config(basedOn: own).json.objectValue?["permissionMode"] == nil)
        var fresh = SubagentForm(scope: .user)
        fresh.permissionMode = .auto
        #expect(fresh.config(basedOn: nil).permissionMode == .auto)
    }

    @Test func serveursMcpToujoursRepris() throws {
        let source = try agent("mcp", extra: ["mcpServers": .array([.object(["name": .string("gh")])])])
        let form = SubagentForm(editing: source, scope: .user)
        #expect(form.config(basedOn: source).mcpServers == source.mcpServers)
    }

    @Test func libellesDesModes() {
        let expected: [(AgentPermissionMode, String)] = [
            (.defaultMode, "Demander (défaut)"), (.acceptEdits, "Accepter les modifications"), (.auto, "Automatique"),
            (.dontAsk, "Ne pas demander"), (.bypassPermissions, "Contourner les autorisations"), (.plan, "Plan"),
        ]
        for (mode, label) in expected { #expect(ExtensionsLabels.permissionMode(mode) == label) }
        #expect(ExtensionsLabels.permissionMode(AgentPermissionMode(rawValue: "futur")) == "futur")
        #expect(ExtensionsLabels.unattendedPermissionWarning
            == "Ce mode laisse le sous-agent agir sur l'hôte sans te demander d'autorisation.")
        #expect(ExtensionsLabels.mcpServers(count: 1) == "1 serveur MCP, non modifiable ici")
        #expect(ExtensionsLabels.mcpServers(count: 3) == "3 serveurs MCP, non modifiables ici")
    }

    // MARK: - Contournement de l'échappement de l'hôte

    /// L'hôte 3.15.1 échappe `"` et `\` à l'écriture sans les rendre à la lecture.
    private func hostRoundTrip(_ description: String) -> String {
        let escaped = description.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return escaped
    }

    @Test func descriptionDeLHoteDesechappee() throws {
        let list = try AgentsListResult(json: try Fixtures.record(in: "v3.15.1/subagents-lifecycle", prefix: "007"))
        let source = try #require(list.userAgents.first)
        #expect(source.description == #"Description avec \"guillemets\" et \\ barre"#)   // tel que l'hôte le renvoie
        let form = SubagentForm(editing: source, scope: .workspace(try #require(source.projectPath)))
        #expect(form.description == #"Description avec "guillemets" et \ barre"#)
        #expect(SubagentForm.hostDescription(source.description) == form.description)
        // Aller-retour : ce qui est envoyé, une fois échappé par l'hôte puis relu, redonne la même description.
        let sent = form.config(basedOn: source).description
        #expect(sent == form.description)
        #expect(SubagentForm.hostDescription(hostRoundTrip(sent)) == sent)
        #expect(hostRoundTrip(sent) == source.description)                   // l'hôte stocke exactement ce qu'il a renvoyé
    }

    @Test func desechappementEnUnSeulPassage() {
        let table: [(String, String)] = [
            (#"a \"b\""#, #"a "b""#), (#"a \\ b"#, #"a \ b"#), (#"\\\""#, #"\""#), (#"\\"#, #"\"#),
            (#"\n reste"#, #"\n reste"#), (#"fin \"#, #"fin \"#), ("simple", "simple"), ("", ""),
            (#"\\"b"#, #"\"b"#),
        ]
        for (read, expected) in table { #expect(SubagentForm.hostDescription(read) == expected, "\(read)") }
    }

    @Test func descriptionDeshappeeSeulementPourUnAgentDeLUtilisateur() throws {
        let raw = ##"Garde \"tel\" quel \\"##
        let user = try agent("perso", extra: ["description": .string(raw)])
        #expect(SubagentForm.displayDescription(of: user) == ##"Garde "tel" quel \"##)
        for source in ["built-in", "plugin"] {
            let other = try agent("autre", extra: ["description": .string(raw), "source": .string(source)])
            #expect(SubagentForm.displayDescription(of: other) == raw, "\(source)")
        }
    }
}
