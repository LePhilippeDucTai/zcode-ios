import Foundation
import ZCodeClient
import ZCodeRPC
import ZCodeV4

/// Libellés français de l'écran « Extensions » (portées, sous-agents). Les textes d'erreur sont définis une seule fois
/// ici : le formulaire d'un sous-agent et la liste affichent les mêmes.
public enum ExtensionsLabels {
    /// « Utilisateur » ou « Projet <dernier composant du chemin> ».
    public static func scope(_ scope: ExtensionScope) -> String {
        switch scope {
        case .user: "Utilisateur"
        case .workspace(let path): "Projet \(URL(filePath: path).lastPathComponent)"
        }
    }

    /// Ce que modifie l'écran : « Mac · Projet mon-projet ».
    public static func target(hostName: String, scope: ExtensionScope) -> String {
        "\(hostName) · \(Self.scope(scope))"
    }

    /// Couleur d'un sous-agent ; une couleur inconnue reste telle quelle.
    public static func color(_ color: AgentColor) -> String {
        switch color {
        case .yellow: "jaune"
        case .red: "rouge"
        case .orange: "orange"
        case .green: "vert"
        case .cyan: "cyan"
        case .blue: "bleu"
        case .purple: "violet"
        case .pink: "rose"
        default: color.rawValue
        }
    }

    /// Absence de liste, liste vide ou joker `*` : tous les outils.
    public static func tools(_ tools: [String]?) -> String {
        guard let tools, !tools.isEmpty, !tools.contains("*") else { return "Tous les outils" }
        return tools.count == 1 ? "1 outil" : "\(tools.count) outils"
    }

    /// `inherit` sans choix ; sinon « <modèle> · <effort> ». Un modèle absent du catalogue (retiré, hôte pas encore lu)
    /// s'affiche par son identifiant brut, sans effort.
    public static func model(_ selection: ModelSelection?, catalog: ModelSelectionView?, inherit: String) -> String {
        guard let selection else { return inherit }
        guard let catalog, catalog.model(providerId: selection.providerId, modelId: selection.modelId) != nil else {
            return selection.modelId
        }
        guard let effort = selection.options?.reasoningLevel else { return selection.modelId }
        return "\(selection.modelId) · \(ChatLabels.effort(effort))"
    }

    /// « Intégré », « Plugin <nom> » ou « Personnalisé ».
    public static func provenance(_ agent: AgentSummary) -> String {
        switch agent.source {
        case .builtIn: return "Intégré"
        case .plugin:
            let name = agent.pluginName ?? agent.pluginId
            return name.map { "Plugin \($0)" } ?? "Plugin"
        default: return "Personnalisé"
        }
    }

    /// Mode d'autorisation d'un sous-agent ; une valeur inconnue reste telle quelle.
    public static func permissionMode(_ mode: AgentPermissionMode) -> String {
        switch mode {
        case .defaultMode: "Demander (défaut)"
        case .acceptEdits: "Accepter les modifications"
        case .auto: "Automatique"
        case .dontAsk: "Ne pas demander"
        case .bypassPermissions: "Contourner les autorisations"
        case .plan: "Plan"
        default: mode.rawValue
        }
    }

    /// Avertissement des modes qui ne demandent jamais d'autorisation (`dontAsk`, `bypassPermissions`).
    public static let unattendedPermissionWarning =
        "Ce mode laisse le sous-agent agir sur l'hôte sans te demander d'autorisation."

    /// Serveurs MCP d'un sous-agent, affichés en lecture seule.
    public static func mcpServers(count: Int) -> String {
        count == 1 ? "1 serveur MCP, non modifiable ici" : "\(count) serveurs MCP, non modifiables ici"
    }

    public static let subagentsTakeEffect = "Pris en compte au prochain tour de chaque conversation."

    /// Bandeau d'une liste déjà lue dont la relecture a échoué : « Hors ligne » seulement pour une panne de connexion
    /// (hôte injoignable, connexion coupée) ; sinon (refus de l'hôte, méthode absente, token refusé) un libellé neutre.
    public static func readOnlyBanner(offline: Bool) -> String {
        offline ? "Hors ligne : liste en lecture seule" : "Lecture impossible : liste en lecture seule"
    }

    /// L'hôte n'offre pas la portée Utilisateur des sous-agents (`capability.userScopeAvailable == false`) ; seul motif
    /// connu en 3.15.1 : `desktop_only`. Un autre motif est montré tel quel, masqué.
    public static func userScopeUnavailable(reason: String?) -> String {
        let base = "Sous-agents de l'utilisateur non pris en charge par cet hôte"
        switch reason {
        case "desktop_only"?: return base + " : réservés à l'application de bureau ZCode."
        case let reason? where !reason.isEmpty: return base + " (\(masked(reason)))."
        default: return base + "."
        }
    }

    // MARK: - Erreurs des sous-agents

    public static let nameLength = "Le nom doit compter de 3 à 50 caractères."
    public static let nameCharacters = "Le nom ne peut contenir que des lettres, des chiffres et des tirets."
    public static let descriptionRequired = "La description est obligatoire."
    public static let instructionsRequired = "Les instructions sont obligatoires."
    public static let nameReserved = "Ce nom est réservé à un sous-agent intégré."
    public static let toolsRequired = "Choisis au moins un outil, ou « Tous les outils »."
    public static let modelUnavailable = "Choisis un modèle disponible avant d'enregistrer."
    public static let effortUnsupported = "Choisis un niveau d'effort pris en charge par ce modèle."
    public static let maxTurnsInvalid = "Nombre de tours : entier supérieur à zéro."
    public static let nameTaken = "Un sous-agent de ce nom existe déjà dans cette portée."
    public static let projectMissing = "Projet manquant pour un sous-agent de projet."
    public static let subagentsServiceStopped = "Le service des sous-agents est arrêté sur l'hôte : redémarre ZCode."
    public static let subagentsUnsupported = "Cette version de ZCode ne gère pas les sous-agents."
    public static let subagentsChannelMissing = "Cette version de ZCode n'expose pas les sous-agents."
    public static let subagentReadOnly = "Ce sous-agent est en lecture seule (intégré ou fourni par un plugin)."
    public static let subagentModelInForm = "Le modèle de ce sous-agent se règle dans son formulaire."

    /// Erreur d'un appel au canal `subagents` : refus du client, messages connus de l'hôte traduits, le reste tel quel mais
    /// masqué (`masked`) : un message brut de l'hôte peut citer une adresse avec ses identifiants.
    public static func subagentFailure(_ error: any Error) -> String {
        if let refusal = error as? SubagentsClientError {
            switch refusal {
            case .readOnly: return subagentReadOnly
            case .notOverridable: return subagentModelInForm
            }
        }
        guard case RPCError.remote(let remote) = error else { return masked(ConnectionFailure(error).message) }
        let text = remote.message
        let known: [(String, String)] = [
            ("Name must be between", nameLength),
            ("Name can only contain", nameCharacters),
            ("Description is required", descriptionRequired),
            ("System prompt is required", instructionsRequired),
            ("reserved by a built-in agent", nameReserved),
            ("already exists", nameTaken),
            ("Workspace path is required", projectMissing),
            ("service is disposed", subagentsServiceStopped),
            ("Method not found", subagentsUnsupported),
            ("Unknown channel", subagentsChannelMissing),
        ]
        if let match = known.first(where: { text.contains($0.0) }) { return match.1 }
        if remote.code == .number(-32601) { return subagentsUnsupported }
        return text.isEmpty ? "Erreur du serveur ZCode." : masked(text)
    }

    // MARK: - Plugins

    /// Catégorie du catalogue ; une catégorie inconnue reste telle quelle.
    public static func category(_ category: String) -> String {
        switch category {
        case "developer-tools": "Outils de développement"
        case "productivity": "Productivité"
        case "finance": "Finance"
        case "utilities": "Utilitaires"
        default: category
        }
    }

    /// Type de composant d'un plugin ; un type inconnu reste tel quel.
    public static func componentKind(_ kind: PluginComponentKind) -> String {
        switch kind {
        case .agent: "Sous-agents"
        case .command: "Commandes"
        case .skill: "Skills"
        case .hook: "Hooks"
        case .mcp: "Serveurs MCP"
        case .lsp: "Serveurs LSP"
        default: kind.rawValue
        }
    }

    /// Titre d'une source : les deux officielles ont un nom français, les autres gardent le leur.
    public static func marketplaceTitle(_ marketplace: MarketplaceSummary) -> String {
        switch marketplace.id {
        case "zcode-plugins-official": "Officiel ZCode"
        case "claude-plugins-official": "Officiel Claude"
        default: marketplace.name.isEmpty ? marketplace.id : marketplace.name
        }
    }

    /// Genre d'une source ; un genre inconnu reste tel quel.
    public static func sourceKind(_ kind: String) -> String {
        switch kind {
        case "github": "GitHub"
        case "git": "Git"
        case "url": "URL"
        case "directory", "file": "Chemin"
        default: kind
        }
    }

    /// Dépôt, adresse ou chemin d'une source, identifiants d'adresse masqués ; `nil` s'il n'y en a pas.
    public static func sourceLabel(_ marketplace: MarketplaceSummary) -> String? {
        guard let label = marketplace.sourceLabel, !label.isEmpty else { return nil }
        return masked(label)
    }

    /// Masque les secrets des adresses d'un texte : la partie « identifiants » (`user:jeton@`) des adresses `schéma://…`
    /// (`https://•••@hôte/…`) et la valeur des paramètres de requête sensibles (`?token=•••`, voir `isSensitiveParameter`).
    /// Les formes sans schéma (`git@hôte:chemin`) et les `@` hors de l'autorité (chemin, requête) restent intacts.
    public static func masked(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let marker = rest.range(of: "://") {
            result += rest[..<marker.upperBound]
            rest = rest[marker.upperBound...]
            let authorityEnd = rest.firstIndex { "/?#".contains($0) || $0.isWhitespace } ?? rest.endIndex
            if let at = rest[..<authorityEnd].lastIndex(of: "@") {
                result += "•••"
                rest = rest[at...]
            }
        }
        return maskingSensitiveParameters(result + rest)
    }

    /// Valeur d'un paramètre `?nom=valeur` / `&nom=valeur` remplacée par `•••` quand le nom est sensible ; la valeur
    /// s'arrête à `&`, `#` ou un blanc.
    private static func maskingSensitiveParameters(_ text: String) -> String {
        text.replacing(/([?&;])([A-Za-z0-9_.\-]+)=([^&#\s]+)/) { match in
            isSensitiveParameter(String(match.output.2)) ? "\(match.output.1)\(match.output.2)=•••" : String(match.output.0)
        }
    }

    /// Nom de paramètre qui porte un secret : jeton, clé, signature, mot de passe, identifiants, session (sans casse ;
    /// `access_token`, `api_key`, `X-Amz-Signature`, `client_secret`…). Masquer trop vaut mieux que montrer un secret.
    private static func isSensitiveParameter(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["token", "secret", "password", "passwd", "pwd", "key", "sig", "auth", "credential", "session"]
            .contains { lowered.contains($0) }
    }

    /// Nom français du catalogue, sinon nom d'affichage, sinon nom du plugin (jamais une chaîne vide).
    public static func pluginDisplayName(_ name: String, listing: PluginListing?) -> String {
        for candidate in [listing?.displayNameI18n["fr"], listing?.displayName] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return name
    }

    /// Description française du catalogue, sinon la description brute ; `nil` si aucune (rien n'est inventé).
    public static func pluginDescription(_ description: String?, listing: PluginListing?) -> String? {
        for candidate in [listing?.descriptionI18n["fr"], description] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    public static func hostExecutionNote(hostName: String) -> String {
        "Les plugins s'exécutent sur \(hostName), jamais sur l'iPhone."
    }

    public static let pluginsTakeEffect =
        "S'applique aux nouvelles sessions ; les conversations ouvertes gardent l'ancienne configuration."

    public static let operationInterrupted =
        "Connexion perdue pendant l'opération : l'hôte l'a peut-être terminée. Liste relue."

    /// Mise en garde avant d'installer : le plugin s'exécute sur l'hôte, d'autant plus s'il lance des programmes
    /// (hooks, serveurs MCP). Une source qui n'est pas connue comme officielle est traitée comme non officielle.
    public static func installWarning(
        plugin: AvailablePlugin, marketplace: MarketplaceSummary?, hostName: String, hasRunnableComponents: Bool
    ) -> String {
        let name = pluginDisplayName(plugin.name, listing: plugin.listing)
        var parts: [String] = []
        if marketplace?.isOfficial != true {
            parts.append("Source non officielle : n'installe que du code de confiance.")
        }
        parts.append("Installer « \(name) » sur \(hostName) ? Le plugin s'exécutera sur \(hostName), jamais sur l'iPhone. "
            + "Il sera installé pour l'utilisateur et actif dans les nouvelles sessions.")
        if hasRunnableComponents {
            parts.append("Il ajoute des commandes automatiques (hooks) ou des serveurs MCP qui lancent des programmes sur l'hôte.")
        }
        return parts.joined(separator: " ")
    }

    /// Libellé d'une opération en cours ; une opération inconnue n'en a pas de plus précis.
    public static func operation(_ kind: PluginOperation.Kind) -> String {
        switch kind {
        case .install: "Installation…"
        case .update: "Mise à jour…"
        case .uninstall: "Désinstallation…"
        case .restore: "Rétablissement…"
        case .enable: "Activation…"
        case .disable: "Désactivation…"
        case .configure: "Enregistrement de la configuration…"
        case .reset: "Réinitialisation…"
        case .addSource: "Ajout de la source…"
        case .removeSource: "Retrait de la source…"
        case .refreshSources: "Actualisation des sources…"
        }
    }

    /// Durée écoulée « m:ss » (jamais négative).
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return "\(total / 60):" + (total % 60 < 10 ? "0" : "") + "\(total % 60)"
    }

    /// Diagnostic de l'hôte : les deux codes connus traduits, le reste rapporté tel quel mais masqué (`masked`) : l'hôte
    /// cite l'adresse brute d'une source (« redirect is missing Location header: <adresse> »).
    public static func diagnostic(_ diagnostic: PluginDiagnostic) -> String {
        switch diagnostic.code {
        case "plugin_operation_cancelled": "Opération annulée."
        case "marketplace_refresh_failed": "Actualisation de la source impossible."
        default: "L'hôte a signalé : \(masked(diagnostic.message))"
        }
    }

    /// Erreur d'un appel au canal `plugin-management` : messages connus de l'hôte traduits, le reste tel quel mais masqué.
    public static func pluginFailure(_ error: any Error) -> String {
        guard case RPCError.remote(let remote) = error else { return masked(ConnectionFailure(error).message) }
        if remote.name == "ZCodeProtocolRequestTimeoutError" {
            return "L'hôte n'a pas répondu à temps ; l'opération continue peut-être."
        }
        let text = remote.message
        let known: [(String, String)] = [
            ("Marketplace source is empty", "Saisis une source."),
            ("path does not exist", "Ce chemin n'existe pas sur l'hôte."),
            ("must be a .json file", "Le fichier de la source doit être un .json."),
            ("Unsupported marketplace source", "Source non prise en charge par l'hôte."),
            ("Marketplace not found", "Source introuvable (retirée entre-temps ?)."),
            ("Plugin not found", "Plugin introuvable sur l'hôte."),
            ("ambiguous", "Nom de plugin ambigu sur l'hôte."),
            ("Method not found", pluginActionUnsupported),
            ("Unknown channel", "Cette version de ZCode n'expose pas la gestion des plugins."),
        ]
        if let match = known.first(where: { text.contains($0.0) }) { return match.1 }
        if remote.code == .number(-32601) { return pluginActionUnsupported }
        return text.isEmpty ? "Erreur du serveur ZCode." : masked(text)
    }

    private static let pluginActionUnsupported = "Cette version de ZCode ne gère pas cette action."
}
