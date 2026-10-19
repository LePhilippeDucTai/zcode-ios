import Foundation
import Observation
import ZCodeClient
import ZCodeRPC
import ZCodeV4

/// Opération en cours sur un plugin ou une source. Une seule à la fois ; `operationId` n'existe que pour celles que l'hôte
/// sait annuler (installation, ajout et actualisation de sources).
public struct PluginOperation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case install, update, uninstall, restore, enable, disable, configure, reset, addSource, removeSource, refreshSources
    }

    public let kind: Kind
    public let targetId: String
    public let operationId: String?
    public let startedAt: Date

    public init(kind: Kind, targetId: String, operationId: String? = nil, startedAt: Date) {
        self.kind = kind
        self.targetId = targetId
        self.operationId = operationId
        self.startedAt = startedAt
    }
}

/// Plugins d'un hôte pour une portée (Utilisateur ou un projet), lus par le canal `plugin-management`. Une lecture à la
/// demande, sans écoute (jamais `onDynamicPluginOperationProgress`). Les plugins ne s'exécutent que sur l'hôte et ne
/// sont pris en compte que par les nouvelles sessions. L'aperçu lu reste affiché si une relecture échoue (hors ligne).
@MainActor
@Observable
public final class PluginsModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var overview: PluginsOverview?
    /// Détail des plugins installés (`listPlugins`) par identifiant `nom@source`.
    public private(set) var details: [String: PluginInfo] = [:]
    /// Composants des plugins du catalogue (`describePlugin`) par identifiant, lus une fois.
    public private(set) var descriptions: [String: PluginDescription] = [:]
    /// Échec de la dernière action (lecture d'une description, puis opérations).
    public private(set) var actionError: String?
    /// Avis après une action réussie ou une demande d'annulation (prise en compte différée).
    public private(set) var notice: String?
    /// Opération en cours : les autres demandes sont ignorées jusqu'à sa fin.
    public private(set) var operation: PluginOperation?
    /// La dernière lecture a échoué faute de connexion (et non par un refus de l'hôte) : bandeau « Hors ligne ».
    public private(set) var isOffline = false
    public let scope: ExtensionScope

    private let connection: HostConnection
    private let now: @Sendable () -> Date
    private let makeOperationId: @Sendable () -> String
    @ObservationIgnored private var generation = 0
    /// Descriptions en cours de lecture : une seule requête par plugin.
    @ObservationIgnored private var describing: Set<String> = []

    public init(
        connection: HostConnection, scope: ExtensionScope,
        now: @escaping @Sendable () -> Date = Date.init,
        makeOperationId: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.connection = connection
        self.scope = scope
        self.now = now
        self.makeOperationId = makeOperationId
    }

    /// Hors ligne, en cours de lecture ou jamais lu : aucune modification possible.
    public var isReadOnly: Bool { phase != .ready }

    /// Une action peut partir : l'hôte est lu (pas hors ligne ni en lecture) et aucune autre opération n'est en cours.
    public var canStartOperation: Bool { !isReadOnly && operation == nil }

    public func layout(query: String, category: String?) -> PluginCatalogLayout {
        PluginCatalogLayout.make(overview ?? PluginsOverview(), query: query, category: category)
    }

    // MARK: - Lecture

    /// À chaque apparition d'un écran : première lecture, nouvel essai après un échec, ou relecture **silencieuse** d'un
    /// aperçu déjà lu. Les opérations touchent tout l'hôte (installation pour l'utilisateur, sources, désinstallation) et
    /// ZCode Web peut aussi le changer : l'aperçu d'une autre portée, mis en cache, serait sinon périmé. La relecture
    /// silencieuse garde l'aperçu affiché, l'avis et l'erreur, sans passage visible en `.loading` ; aucune relecture
    /// pendant une opération (elle se termine par la sienne) ni pendant une lecture en vol.
    public func loadIfNeeded() async {
        // Les messages ne s'effacent qu'à la première lecture : au retour d'un détail, l'erreur affichée reste.
        if phase == .idle, operation == nil { dismissMessages() }
        switch phase {
        case .idle, .failed: await reload(announcing: true)
        case .ready:
            guard operation == nil else { return }
            // Tâche détachée de l'appelant : `.task` est annulé quand l'écran disparaît (détail poussé, autre rubrique),
            // et une relecture annulée afficherait une erreur à la place de la liste.
            await Task { await self.reload(announcing: false) }.value
        case .loading: return
        }
    }

    /// Relit l'aperçu et le détail des installés en parallèle ; un appel en vol est abandonné au profit du plus récent.
    public func refresh() async {
        // Pendant une opération (et pour la relecture qui la clôt), l'avis et l'erreur de l'opération restent.
        if operation == nil { dismissMessages() }
        await reload(announcing: true)
    }

    /// `announcing == false` : la phase reste `.ready` pendant la lecture (relecture silencieuse) ; un échec la fait
    /// quand même passer en `.failed`, l'aperçu lu restant affiché en lecture seule.
    private func reload(announcing: Bool) async {
        generation += 1
        let generation = self.generation
        if announcing { phase = .loading }
        do {
            let client = try await makeClient()
            async let overview = client.overview(scope: scope)
            async let list = client.list(scope: scope)
            let (read, listed) = try await (overview, list)
            guard generation == self.generation else { return }
            isOffline = false
            guard read.supported else {
                // L'hôte ne gère plus les plugins : rien de l'aperçu précédent ne reste affiché comme encore valable.
                self.overview = nil
                details = [:]
                phase = .failed(Self.unsupported(reason: read.unsupportedReason))
                return
            }
            self.overview = read
            details = Dictionary(listed.plugins.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            phase = .ready
        } catch {
            guard generation == self.generation else { return }
            isOffline = ExtensionsHost.isOffline(error)
            phase = .failed("Plugins indisponibles : \(Self.message(error))")
        }
    }

    private static func unsupported(reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return "Gestion des plugins non prise en charge par cet hôte." }
        return "Gestion des plugins non prise en charge par cet hôte (\(ExtensionsLabels.masked(reason)))."
    }

    /// Lit les composants d'un plugin du catalogue, une fois par identifiant. Un échec (appel ou refus de l'hôte) va dans
    /// `actionError` et n'est pas gardé : l'ouverture suivante réessaie.
    public func describe(_ plugin: AvailablePlugin) async {
        guard descriptions[plugin.id] == nil, describing.insert(plugin.id).inserted else { return }
        defer { describing.remove(plugin.id) }
        // Une tentative effective repart sans l'erreur périmée d'une lecture précédente (sauf celle d'une opération).
        if operation == nil { actionError = nil }
        do {
            let client = try await makeClient()
            let description = try await client.describe(plugin, scope: scope)
            if description.failed {
                actionError = description.diagnostics.first(where: \.isError).map(ExtensionsLabels.diagnostic)
            } else {
                descriptions[plugin.id] = description
            }
        } catch {
            actionError = Self.message(error)
        }
    }

    public func dismissMessages() {
        actionError = nil
        notice = nil
    }

    // MARK: - Opérations

    /// Un plugin du catalogue lance-t-il des programmes sur l'hôte (hooks ou serveurs MCP) ? Les types annoncés par le
    /// catalogue et les composants lus par `describe` comptent tous deux.
    public func hasRunnableComponents(_ plugin: AvailablePlugin) -> Bool {
        let runnable: [PluginComponentKind] = [.hook, .mcp]
        if plugin.componentTypes.contains(where: runnable.contains) { return true }
        return descriptions[plugin.id]?.components.contains { runnable.contains($0.kind) && !$0.items.isEmpty } ?? false
    }

    /// Installe pour l'utilisateur (l'hôte ignore la portée), avec un identifiant d'opération pour pouvoir l'annuler.
    public func install(_ plugin: AvailablePlugin) async {
        let operationId = makeOperationId()
        let name = ExtensionsLabels.pluginDisplayName(plugin.name, listing: plugin.listing)
        await perform(.install, target: plugin.id, operationId: operationId, success: "« \(name) » installé.") { client, scope in
            try await client.install(plugin, operationId: operationId, scope: scope).failure
        }
    }

    public func update(_ plugin: InstalledPlugin) async {
        let name = ExtensionsLabels.pluginDisplayName(plugin.name, listing: plugin.listing)
        await perform(.update, target: plugin.id, success: "« \(name) » mis à jour.") { client, scope in
            try await client.update(pluginId: plugin.id, scope: scope).failure
        }
    }

    public func uninstall(_ plugin: InstalledPlugin) async {
        let name = ExtensionsLabels.pluginDisplayName(plugin.name, listing: plugin.listing)
        await perform(.uninstall, target: plugin.id, success: "« \(name) » désinstallé.") { client, scope in
            try await client.uninstall(pluginId: plugin.id, scope: scope).first(where: \.isError)
        }
    }

    /// Rétablit un plugin intégré masqué par une désinstallation.
    public func restore(_ plugin: AvailablePlugin) async {
        let name = ExtensionsLabels.pluginDisplayName(plugin.name, listing: plugin.listing)
        await perform(.restore, target: plugin.id, success: "« \(name) » rétabli.") { client, scope in
            try await client.restoreBuiltin(pluginId: plugin.id, scope: scope).first(where: \.isError)
        }
    }

    /// Active ou désactive dans la portée du modèle (Utilisateur ou le projet).
    public func setEnabled(_ plugin: InstalledPlugin, _ enabled: Bool) async {
        let notice = (enabled ? "Activé pour " : "Désactivé pour ") + ExtensionsLabels.scope(scope) + "."
        await perform(enabled ? .enable : .disable, target: plugin.id, success: notice) { client, scope in
            try await client.setEnabled(pluginId: plugin.id, enabled, scope: scope)
            return nil
        }
    }

    /// Enregistre les champs modifiés d'un formulaire dans la portée du modèle. Les valeurs sensibles partent vers
    /// l'hôte et ne sont gardées nulle part ici. `false` : rien envoyé (aucun champ modifié, formulaire invalide ou d'une
    /// autre portée), refus, échec ou connexion perdue.
    public func configure(_ plugin: InstalledPlugin, form: PluginConfigForm) async -> Bool {
        let patch = form.patch()
        // Un formulaire d'une autre portée n'a pas les bonnes règles d'effacement : refusé.
        guard form.scope == scope, form.issues().isEmpty, !patch.isEmpty else { return false }
        let name = ExtensionsLabels.pluginDisplayName(plugin.name, listing: plugin.listing)
        return await perform(.configure, target: plugin.id, success: "Configuration de « \(name) » enregistrée.") { client, scope in
            try await client.configure(pluginId: plugin.id, options: patch.options, clearing: patch.clearKeys, scope: scope)
                .first(where: \.isError)
        }
    }

    /// Efface la configuration du plugin dans la portée du modèle (Utilisateur ou le projet). `false` : refus (modèle en
    /// lecture seule ou autre opération en cours, sans erreur affichée), échec ou connexion perdue.
    @discardableResult
    public func resetConfig(_ plugin: InstalledPlugin) async -> Bool {
        let name = ExtensionsLabels.pluginDisplayName(plugin.name, listing: plugin.listing)
        return await perform(.reset, target: plugin.id, success: "Configuration de « \(name) » réinitialisée.") { client, scope in
            try await client.resetConfig(pluginId: plugin.id, scope: scope).first(where: \.isError)
        }
    }

    // MARK: - Sources

    /// Texte d'une source tel que l'hôte le reçoit : sans espaces ni retours à la ligne autour.
    private static func cleaned(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Contrôle local d'une source avant tout appel : `nil` si le texte peut partir. Un chemin relatif se résoudrait dans un
    /// dossier interne de l'hôte, donc il est refusé ; le reste (`owner/repo`, adresse, `user@hôte:chemin`, chemin absolu
    /// ou `~`) est laissé à l'hôte.
    public static func sourceIssue(_ text: String) -> String? {
        let source = cleaned(text)
        if source.isEmpty { return "Saisis une source." }
        if source.hasPrefix("./") || source.hasPrefix("../") { return "Chemin absolu attendu (sur l'hôte)." }
        return nil
    }

    /// Fait vérifier la source par l'hôte sans l'ajouter (`dryRun`). `nil` : l'hôte l'accepte ; sinon le message à montrer.
    /// Ce n'est pas une opération : ni l'avis, ni l'erreur, ni `operation` ne changent.
    public func validateSource(_ text: String) async -> String? {
        let source = Self.cleaned(text)
        if let issue = Self.sourceIssue(source) { return issue }
        do {
            let client = try await makeClient()
            let result = try await client.addMarketplace(source: source, dryRun: true, operationId: nil, scope: scope)
            return result.failure.map(ExtensionsLabels.diagnostic)
        } catch {
            return Self.message(error)
        }
    }

    /// Ajoute une source, avec un identifiant d'opération pour pouvoir l'annuler. `false` : texte refusé (message dans
    /// `actionError`, aucun appel), autre opération en cours ou lecture seule (rien d'affiché), refus ou échec de l'hôte.
    public func addSource(_ text: String) async -> Bool {
        guard canStartOperation else { return false }
        let source = Self.cleaned(text)
        if let issue = Self.sourceIssue(source) {
            dismissMessages()
            actionError = issue
            return false
        }
        let operationId = makeOperationId()
        return await perform(.addSource, target: ExtensionsLabels.masked(source), operationId: operationId) { client, scope in
            let result = try await client.addMarketplace(source: source, dryRun: false, operationId: operationId, scope: scope)
            if let failure = result.failure { return .failure(failure) }
            let name = result.marketplace.map(ExtensionsLabels.marketplaceTitle) ?? ExtensionsLabels.masked(source)
            return .success("Source « \(name) » ajoutée.")
        }
    }

    /// Retire une source ; les plugins installés restent. Les deux officielles ne se retirent pas (l'hôte les recréerait).
    public func removeSource(_ marketplace: MarketplaceSummary) async {
        guard canStartOperation else { return }
        guard !marketplace.isOfficial else {
            dismissMessages()
            actionError = "Les sources officielles ne se retirent pas."
            return
        }
        await perform(.removeSource, target: marketplace.id,
                      success: "Source retirée ; ses plugins installés restent, sans mises à jour.") { client, scope in
            try await client.removeMarketplace(id: marketplace.id, scope: scope).first(where: \.isError)
        }
    }

    /// `PluginOperation.targetId` de l'actualisation de toutes les sources (aucune source en particulier).
    private static let allSourcesTarget = "*"

    /// Actualise toutes les sources ; annulable. L'échec d'une source reste visible sur sa ligne (`refreshFailure`).
    public func refreshSources() async {
        let operationId = makeOperationId()
        await perform(.refreshSources, target: Self.allSourcesTarget, operationId: operationId, success: "Sources actualisées.") { client, scope in
            try await client.refreshMarketplace(id: nil, operationId: operationId, scope: scope).failure
        }
    }

    /// Demande à l'hôte d'annuler l'opération en cours (l'annulation de l'appel RPC ne ferait rien côté hôte). L'issue de
    /// l'opération elle-même arrive par sa propre réponse.
    public func cancelOperation() async {
        guard let id = operation?.operationId else { return }
        do {
            let client = try await makeClient()
            let cancelled = try await client.cancel(operationId: id)
            // L'opération a pu finir entre-temps : son issue (avis ou erreur) ne doit pas être écrasée.
            guard operation?.operationId == id else { return }
            notice = cancelled ? "Annulation demandée." : "Rien à annuler : l'opération est déjà terminée."
        } catch {
            guard operation?.operationId == id else { return }
            actionError = Self.message(error)
        }
    }

    /// Issue d'une action de `perform` : l'avis de succès, ou le diagnostic d'échec rapporté par l'hôte.
    private enum Outcome {
        case success(String)
        case failure(PluginDiagnostic)
    }

    /// Variante à avis fixe : `action` rend le diagnostic d'échec, `nil` si l'opération a réussi.
    @discardableResult
    private func perform(
        _ kind: PluginOperation.Kind, target: String, operationId: String? = nil, success: String,
        _ action: @Sendable (PluginManagementClient, ExtensionScope) async throws -> PluginDiagnostic?
    ) async -> Bool {
        await perform(kind, target: target, operationId: operationId) { client, scope in
            if let failure = try await action(client, scope) { return .failure(failure) }
            return .success(success)
        }
    }

    /// Une opération à la fois (les autres demandes sont ignorées), hors ligne comprise. Elle se termine toujours par une
    /// relecture, réussie ou non, puis `operation` repasse à `nil` ; elle rend `true` si l'opération a réussi. Un échec
    /// rapporté par l'hôte dans les diagnostics d'une réponse de succès est un échec ; une connexion perdue en cours
    /// d'opération laisse l'issue inconnue. L'avis de succès peut dépendre de la réponse (nom de la source ajoutée).
    @discardableResult
    private func perform(
        _ kind: PluginOperation.Kind, target: String, operationId: String? = nil,
        _ action: @Sendable (PluginManagementClient, ExtensionScope) async throws -> Outcome
    ) async -> Bool {
        guard canStartOperation else { return false }
        operation = PluginOperation(kind: kind, targetId: target, operationId: operationId, startedAt: now())
        dismissMessages()
        var succeeded = false
        do {
            let client = try await makeClient()
            switch try await action(client, scope) {
            case .failure(let failure):
                actionError = ExtensionsLabels.diagnostic(failure)
            case .success(let text):
                notice = text + " " + ExtensionsLabels.pluginsTakeEffect
                succeeded = true
            }
        } catch {
            actionError = Self.isConnectionLoss(error) ? ExtensionsLabels.operationInterrupted : Self.message(error)
        }
        await refresh()
        operation = nil
        return succeeded
    }

    private static func isConnectionLoss(_ error: any Error) -> Bool {
        guard let rpc = error as? RPCError else { return false }
        switch rpc {
        case .connectionClosed, .transport: return true
        default: return false
        }
    }

    // MARK: - Connexion

    /// Le canal exige un projet de l'hôte (voir `ExtensionsHost`).
    private func makeClient() async throws -> PluginManagementClient {
        let (channel, workspace) = try await ExtensionsHost.channelAndWorkspace(connection: connection, scope: scope)
        return PluginManagementClient(client: channel, hostWorkspace: workspace)
    }

    private static func message(_ error: any Error) -> String {
        ExtensionsHost.message(error, otherwise: ExtensionsLabels.pluginFailure)
    }
}
