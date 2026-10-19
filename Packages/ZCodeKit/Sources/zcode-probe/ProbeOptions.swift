import Foundation

struct ProbeOptions: Equatable {
    enum Command: Equatable {
        case info
        case run(URL)
        case check
        case goal
        case attach
        case extensions
        case composer
        case workflows
    }

    /// `composer` : scénario du lancement (un prompt GLM au plus par lancement).
    enum ComposerScenario: Equatable {
        /// Aucun prompt : session vide, catalogue des skills, présentation, suppression.
        case quiet
        /// Un prompt : « PONG » puis `forkAssistant`.
        case fork
        /// Un prompt et un petit run : `/workflow …`, run annulé dès qu'il apparaît.
        case workflow
    }

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    var command: Command
    var url = URL(string: "http://127.0.0.1:3030")!
    var tokenFile: URL
    /// Token fourni par `ZCODE_TOKEN` (prioritaire sur le fichier).
    var token: String?
    var recordDirectory: URL?
    /// Espace de travail de l'hôte (chemin absolu côté serveur).
    var workspace: String
    /// Dossier de la source de plugins jetable, côté hôte (`extensions`).
    var marketplace: String?
    /// `extensions` : invoque aussi le sous-agent jetable (≈ 6 appels au modèle observés).
    var invoke = false
    var composerScenario = ComposerScenario.quiet
    /// `workflows` : lance aussi le workflow avec un agent qui demande à écrire un fichier (quelques prompts GLM).
    public var workflowsWithAgent = false
    /// `workflows --with-agent --cancel` : « Arrêter » (`cancelBackgroundWork`) pendant que la demande de l'agent
    /// attend, au lieu de la refuser.
    var workflowsCancelWhilePending = false
    /// `workflows` : mode demandé à la création des sessions (`createSession.config.mode`) ; `nil` = rien d'envoyé.
    var sessionMode: String?

    static func parse(_ arguments: [String], environment: [String: String]) throws(ParseError) -> ProbeOptions {
        var rest = arguments[...]
        guard let verb = rest.popFirst() else {
            throw ParseError(description: "commande manquante")
        }
        let home = URL(filePath: environment["HOME"] ?? NSHomeDirectory())
        var options = ProbeOptions(
            command: .info,
            tokenFile: home.appending(path: ".config/zcode-web/token"),
            workspace: environment["ZCODE_PROBE_WORKSPACE"] ?? home.path
        )
        switch verb {
        case "info":
            options.command = .info
        case "run":
            guard let script = rest.popFirst(), !script.hasPrefix("--") else {
                throw ParseError(description: "script manquant")
            }
            options.command = .run(URL(filePath: script))
        case "check":
            options.command = .check
        case "goal":
            options.command = .goal
        case "attach":
            options.command = .attach
        case "extensions":
            options.command = .extensions
        case "composer":
            options.command = .composer
        case "workflows":
            options.command = .workflows
        default:
            throw ParseError(description: "commande inconnue : \(verb)")
        }
        while let flag = rest.popFirst() {
            // Drapeaux sans valeur.
            if flag == "--invoke" {
                guard options.command == .extensions else {
                    throw ParseError(description: "--invoke ne vaut que pour extensions")
                }
                options.invoke = true
                continue
            }
            if flag == "--with-agent" {
                guard options.command == .workflows else {
                    throw ParseError(description: "--with-agent ne vaut que pour workflows")
                }
                options.workflowsWithAgent = true
                continue
            }
            if flag == "--cancel" {
                guard options.command == .workflows else {
                    throw ParseError(description: "--cancel ne vaut que pour workflows")
                }
                options.workflowsCancelWhilePending = true
                continue
            }
            if flag == "--fork" || flag == "--workflow" {
                guard options.command == .composer else {
                    throw ParseError(description: "\(flag) ne vaut que pour composer")
                }
                guard options.composerScenario == .quiet else {
                    throw ParseError(description: "--fork et --workflow s'excluent : un prompt par lancement")
                }
                options.composerScenario = flag == "--fork" ? .fork : .workflow
                continue
            }
            guard let value = rest.popFirst() else {
                throw ParseError(description: "valeur manquante pour \(flag)")
            }
            switch flag {
            case "--url":
                guard let url = URL(string: value), url.scheme != nil, url.host() != nil else {
                    throw ParseError(description: "URL invalide : \(value)")
                }
                options.url = url
            case "--token-file":
                options.tokenFile = URL(filePath: value)
            case "--record":
                options.recordDirectory = URL(filePath: value)
            case "--workspace":
                guard value.hasPrefix("/") else {
                    throw ParseError(description: "--workspace attend un chemin absolu : \(value)")
                }
                options.workspace = value
            case "--marketplace":
                guard options.command == .extensions else {
                    throw ParseError(description: "--marketplace ne vaut que pour extensions")
                }
                guard value.hasPrefix("/") else {
                    throw ParseError(description: "--marketplace attend un chemin absolu : \(value)")
                }
                options.marketplace = value
            case "--mode":
                guard options.command == .workflows else {
                    throw ParseError(description: "--mode ne vaut que pour workflows")
                }
                options.sessionMode = value
            default:
                throw ParseError(description: "option inconnue : \(flag)")
            }
        }
        if [.extensions, .composer, .workflows].contains(options.command) {
            try checkScratchWorkspace(options)
        }
        if options.workflowsCancelWhilePending, !options.workflowsWithAgent {
            throw ParseError(description: "--cancel exige --with-agent")
        }
        if options.command == .extensions, options.marketplace == nil {
            throw ParseError(description: "--marketplace est obligatoire pour extensions")
        }
        if let token = environment["ZCODE_TOKEN"], !token.isEmpty {
            options.token = token
        }
        return options
    }

    /// `extensions`, `composer` et `workflows` écrivent dans l'espace de travail (agents, sessions jetables) : seulement sous un
    /// dossier `.zcode-check`, jamais dans un vrai projet (l'espace par défaut est donc refusé).
    private static func checkScratchWorkspace(_ options: ProbeOptions) throws(ParseError) {
        let components = options.workspace.split(separator: "/")
        guard options.workspace.contains("/.zcode-check/"), !components.contains("..") else {
            throw ParseError(description: "--workspace doit désigner un dossier sous .zcode-check : \(options.workspace)")
        }
    }

    func loadToken() throws -> String {
        if let token {
            return token
        }
        let token = try String(contentsOf: tokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ParseError(description: "token vide : \(tokenFile.path)")
        }
        return token
    }
}
