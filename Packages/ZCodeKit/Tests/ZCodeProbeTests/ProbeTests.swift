import Foundation
import Testing
@testable import zcode_probe
import ZCodeWire

struct ProbeTests {
    let environment = ["HOME": "/Users/test", "SESSION_ID": "sess_1"]

    @Test func optionsParDefaut() throws {
        let options = try ProbeOptions.parse(["info"], environment: environment)
        #expect(options.command == .info)
        #expect(options.url == URL(string: "http://127.0.0.1:3030")!)
        #expect(options.tokenFile.path == "/Users/test/.config/zcode-web/token")
        #expect(options.token == nil)
        #expect(options.recordDirectory == nil)
        #expect(options.workspace == "/Users/test")
    }

    @Test func optionsDeRun() throws {
        var environment = environment
        environment["ZCODE_TOKEN"] = "jeton"
        let options = try ProbeOptions.parse(
            ["run", "s.json", "--url", "https://h.ts.net", "--record", "/tmp/out"], environment: environment)
        #expect(options.command == .run(URL(filePath: "s.json")))
        #expect(options.url == URL(string: "https://h.ts.net")!)
        #expect(options.recordDirectory == URL(filePath: "/tmp/out"))
        #expect(try options.loadToken() == "jeton")
    }

    @Test func refuseLesArgumentsInvalides() {
        #expect(throws: ProbeOptions.ParseError.self) { try ProbeOptions.parse([], environment: environment) }
        #expect(throws: ProbeOptions.ParseError.self) { try ProbeOptions.parse(["run"], environment: environment) }
        #expect(throws: ProbeOptions.ParseError.self) { try ProbeOptions.parse(["info", "--inconnu", "x"], environment: environment) }
        #expect(throws: ProbeOptions.ParseError.self) { try ProbeOptions.parse(["info", "--url"], environment: environment) }
    }

    @Test func scriptAvecSubstitutionDesVariables() throws {
        let script = try ProbeScript.parse(#"""
        {"steps": [
          {"call": "zcode-agent", "method": "helloConversationV4"},
          {"listen": "zcode-agent", "event": "onDynamicConversationFrame", "arg": {"workspacePath": "${HOME}/claude"}},
          {"call": "zcode-agent", "method": "subscribeConversationV4",
           "args": [{"workspacePath": "${HOME}/claude", "sessionId": "${SESSION_ID}"}]},
          {"wait": 1.5}
        ]}
        """#, environment: environment)
        #expect(script.steps == [
            .call(channel: "zcode-agent", method: "helloConversationV4", args: []),
            .listen(channel: "zcode-agent", event: "onDynamicConversationFrame",
                    arg: .object(["workspacePath": .string("/Users/test/claude")])),
            .call(channel: "zcode-agent", method: "subscribeConversationV4",
                  args: [.object(["workspacePath": .string("/Users/test/claude"), "sessionId": .string("sess_1")])]),
            .wait(seconds: 1.5),
        ])
    }

    @Test func signaleLesVariablesManquantes() {
        #expect(throws: ProbeScriptError.missingVariables(["COMMAND_ID"])) {
            try ProbeScript.parse(#"{"steps":[{"call":"c","method":"m","args":["${COMMAND_ID}"]}]}"#, environment: environment)
        }
    }

    @Test func refuseUneEtapeInconnue() {
        #expect(throws: DecodingError.self) {
            try ProbeScript.parse(#"{"steps":[{"dance":"x"}]}"#, environment: environment)
        }
    }

    @Test func optionsDeCheck() throws {
        let defaults = try ProbeOptions.parse(["check"], environment: environment)
        #expect(defaults.command == .check)
        #expect(defaults.workspace == "/Users/test")
        let custom = try ProbeOptions.parse(["check", "--workspace", "/tmp/espace", "--url", "https://h.ts.net"], environment: environment)
        #expect(custom.workspace == "/tmp/espace")
        #expect(throws: ProbeOptions.ParseError.self) {
            try ProbeOptions.parse(["check", "--workspace", "relatif"], environment: environment)
        }
    }

    @Test func optionsDeGoal() throws {
        let options = try ProbeOptions.parse(["goal", "--record", "/tmp/goal-rec"], environment: environment)
        #expect(options.command == .goal)
        #expect(options.recordDirectory?.path == "/tmp/goal-rec" && options.workspace == "/Users/test")
    }

    @Test func optionsDePieceJointe() throws {
        let options = try ProbeOptions.parse(["attach", "--record", "/tmp/attach-rec"], environment: environment)
        #expect(options.command == .attach)
        #expect(options.recordDirectory?.path == "/tmp/attach-rec" && options.workspace == "/Users/test")
    }

    @Test func optionsDExtensions() throws {
        let workspace = "/h/claude/.zcode-check/extensions"
        let marketplace = "/h/claude/.zcode-check/marketplace"
        let options = try ProbeOptions.parse(
            ["extensions", "--workspace", workspace, "--marketplace", marketplace, "--invoke"], environment: environment)
        #expect(options.command == .extensions)
        #expect(options.workspace == workspace && options.marketplace == marketplace && options.invoke)
        let quiet = try ProbeOptions.parse(
            ["extensions", "--marketplace", marketplace, "--workspace", workspace, "--record", "/tmp/ext"], environment: environment)
        #expect(!quiet.invoke && quiet.recordDirectory?.path == "/tmp/ext")
        // Chemin relatif, source manquante, espace par défaut (~/claude) ou hors de `.zcode-check` : refusés.
        for arguments in [
            ["extensions", "--workspace", workspace, "--marketplace", "relatif"],
            ["extensions", "--workspace", workspace],
            ["extensions", "--marketplace", marketplace],
            ["extensions", "--workspace", "/h/claude/projet", "--marketplace", marketplace],
            ["extensions", "--workspace", "/h/claude/.zcode-check/../projet", "--marketplace", marketplace],
            ["check", "--invoke"],
        ] {
            #expect(throws: ProbeOptions.ParseError.self) { try ProbeOptions.parse(arguments, environment: environment) }
        }
    }

    @Test func workflowsSansEtAvecAgent() throws {
        let plain = try ProbeOptions.parse(["workflows", "--workspace", "/tmp/w/.zcode-check/workflows"], environment: environment)
        #expect(plain.command == .workflows)
        #expect(plain.workflowsWithAgent == false)
        #expect(plain.sessionMode == nil)
        let agent = try ProbeOptions.parse(["workflows", "--workspace", "/tmp/w/.zcode-check/workflows", "--with-agent"],
                                           environment: environment)
        #expect(agent.workflowsWithAgent == true)
        let build = try ProbeOptions.parse(["workflows", "--with-agent", "--mode", "build", "--workspace", "/tmp/w/.zcode-check/workflows"],
                                           environment: environment)
        #expect(build.sessionMode == "build")
        #expect(build.workflowsCancelWhilePending == false)
        let cancel = try ProbeOptions.parse(["workflows", "--with-agent", "--cancel", "--workspace", "/tmp/w/.zcode-check/workflows"],
                                            environment: environment)
        #expect(cancel.workflowsCancelWhilePending == true)
        // Projet jetable obligatoire ; --with-agent et --mode propres à workflows.
        for arguments in [
            ["workflows"],
            ["workflows", "--workspace", "/tmp/w/projet"],
            ["check", "--with-agent"],
            ["check", "--mode", "build"],
            ["workflows", "--cancel", "--workspace", "/tmp/w/.zcode-check/workflows"],
            ["check", "--cancel"],
        ] {
            #expect(throws: ProbeOptions.ParseError.self) { try ProbeOptions.parse(arguments, environment: environment) }
        }
    }

    @Test func optionsDuComposeur() throws {
        let workspace = "/h/claude/.zcode-check/composer"
        let quiet = try ProbeOptions.parse(["composer", "--workspace", workspace], environment: environment)
        #expect(quiet.command == .composer && quiet.composerScenario == .quiet && quiet.workspace == workspace)
        let fork = try ProbeOptions.parse(["composer", "--fork", "--workspace", workspace, "--record", "/tmp/fork"],
                                          environment: environment)
        #expect(fork.composerScenario == .fork && fork.recordDirectory?.path == "/tmp/fork")
        let workflow = try ProbeOptions.parse(["composer", "--workspace", workspace, "--workflow"], environment: environment)
        #expect(workflow.composerScenario == .workflow)
        // Un prompt par lancement ; projet jetable obligatoire ; options propres au composeur.
        for arguments in [
            ["composer", "--workspace", workspace, "--fork", "--workflow"],
            ["composer"],
            ["composer", "--workspace", "/h/claude"],
            ["check", "--fork"],
            ["goal", "--workflow"],
        ] {
            #expect(throws: ProbeOptions.ParseError.self) { try ProbeOptions.parse(arguments, environment: environment) }
        }
    }

    @Test func masquageDesSecrets() {
        let value: JSONValue = .object([
            "providers": .array([.object([
                "effectiveConfig": .object(["access": .object(["apiKey": .string("sk-secret"), "type": .string("api-key")])]),
                "providerName": .string("Mistral"),
            ])]),
            "Authorization": .string("Bearer x"),
            "token": .null,
            "tokens": .number(12),
        ])
        #expect(value.redactingSecrets() == .object([
            "providers": .array([.object([
                "effectiveConfig": .object(["access": .object(["apiKey": .string("••••"), "type": .string("api-key")])]),
                "providerName": .string("Mistral"),
            ])]),
            "Authorization": .string("••••"),
            "token": .null,
            "tokens": .number(12),
        ]))
    }

    @Test func rapportDeContrat() {
        var report = CheckReport()
        report.record("handshake V4", .passed, duration: .milliseconds(1500))
        report.record("approbation", .warning("aucune demande d'approbation : chemin non exercé"))
        #expect(report.succeeded)
        report.record("changements de fichiers du tour", .failed("fichier absent du diff"), duration: .seconds(2))
        #expect(!report.succeeded)
        #expect(report.entries.map { CheckReport.line(for: $0) } == [
            "✓ handshake V4 (1.5 s)",
            "⚠ approbation : aucune demande d'approbation : chemin non exercé",
            "✗ changements de fichiers du tour (2.0 s) : fichier absent du diff",
        ])
        #expect(!CheckReport().succeeded)
    }

    @Test func masquageDesSecretsParMotif() {
        let value: JSONValue = .object([
            "codingPlanApiKey": .string("k1"), "zcodeJwtToken": .string("k2"), "clientSecret": .string("k3"),
            "legacy_auth_token": .string("k4"), "proxyAuthorization": .string("k5"), "dbPassword": .string("k6"),
            "usedTokens": .number(19_941), "maxTokens": .number(1_000_000), "tokenizer": .string("o200k"),
        ])
        #expect(value.redactingSecrets() == .object([
            "codingPlanApiKey": .string("••••"), "zcodeJwtToken": .string("••••"), "clientSecret": .string("••••"),
            "legacy_auth_token": .string("••••"), "proxyAuthorization": .string("••••"), "dbPassword": .string("••••"),
            "usedTokens": .number(19_941), "maxTokens": .number(1_000_000), "tokenizer": .string("o200k"),
        ]))
    }
}
