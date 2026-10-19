import Foundation
import Observation
import ZCodeClient
import ZCodeV4

/// Utilisation du Coding Plan d'un hôte (canal `usage-stats`), lue pour un fournisseur par compte de son catalogue
/// (`ModelCatalog` : `config.access` de type `zhipu-account`). Une lecture à la demande, sans écoute : l'hôte ne publie
/// aucun changement de quota. Les réinitialisations sont lues avec les quotas : le statut ne liste que les
/// opportunités déjà accordées, l'éligibilité est redemandée au fournisseur à chaque lecture (un refus ou une limite
/// de débit n'est pas une erreur) ; en consommer une (`useReset`) est la seule action, une à la fois, confirmée par
/// l'historique du type puis suivie d'une relève des jauges.
@MainActor
@Observable
public final class UsageModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        /// Réponse reçue (`snapshot`), même sans quota (`unavailableReason`).
        case ready
        /// Le catalogue de l'hôte n'a aucun fournisseur par compte dont les quotas se lisent.
        case noAccount
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var snapshot: UsageEntitlementSnapshot?
    /// Heure de la dernière lecture réussie (horloge de l'app).
    public private(set) var updatedAt: Date?
    /// Fournisseur choisi par l'utilisateur ; `nil` : celui de la sélection préférée de l'hôte, sinon le premier lisible.
    public private(set) var selectedProviderId: String?

    /// Réinitialisations accordées et non consommées ; survit à un échec de lecture.
    public private(set) var resetStatus: CodingPlanResetStatus?
    /// La lecture des réinitialisations a échoué (les jauges restent affichées).
    public private(set) var resetIssue: String?
    /// Une consommation est en vol ; une seule à la fois.
    public private(set) var isResetting = false
    /// Succès de la dernière consommation ; effacé au début de la suivante, pas par les relectures.
    public private(set) var resetNotice: String?
    /// Échec de la dernière consommation ; même durée de vie que le succès.
    public private(set) var resetError: String?

    private let connection: HostConnection
    private let catalog: ModelCatalog
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Attente entre deux lectures de confirmation après une consommation (injectable pour les tests).
    @ObservationIgnored private let pause: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private var generation = 0

    public init(connection: HostConnection, catalog: ModelCatalog, now: @escaping @Sendable () -> Date = Date.init,
                pause: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }) {
        self.connection = connection
        self.catalog = catalog
        self.now = now
        self.pause = pause
    }

    /// Part restante (0–100) de la fenêtre glissante de 5 heures, pour le rappel de la conversation ; `nil` sans lecture
    /// ou sans cette fenêtre.
    public var fiveHoursRemaining: Double? {
        snapshot?.limit(for: .fiveHours)?.remainingPercentage
    }

    /// Fournisseurs par compte du catalogue dont les quotas se lisent, dans l'ordre de l'hôte.
    public var providers: [ModelSelectionView.Provider] {
        catalog.view?.providers.filter { $0.accountAccess?.canReadUsage == true } ?? []
    }

    /// Fournisseur interrogé.
    public var provider: ModelSelectionView.Provider? {
        let providers = providers
        if let selectedProviderId, let chosen = providers.first(where: { $0.providerId == selectedProviderId }) {
            return chosen
        }
        if let preferred = catalog.view?.preferredSelection?.providerId,
           let chosen = providers.first(where: { $0.providerId == preferred }) {
            return chosen
        }
        return providers.first
    }

    /// Ouverture de l'écran : première lecture, nouvel essai après un échec ou un catalogue sans compte, relecture d'une
    /// réponse de plus de `maxAge` secondes (les quotas bougent à chaque tour). Une réponse récente reste affichée (bouton
    /// et tirer pour actualiser) ; une lecture en vol n'est pas doublée.
    public func loadIfNeeded(maxAge: TimeInterval = 60) async {
        switch phase {
        case .loading:
            return
        case .ready:
            guard let updatedAt, now().timeIntervalSince(updatedAt) > maxAge else { return }
            await refresh()
        case .idle, .noAccount, .failed:
            await refresh()
        }
    }

    /// Relit le catalogue si besoin puis les quotas ; un appel en vol est abandonné au profit du plus récent.
    public func refresh() async {
        generation += 1
        let generation = self.generation
        phase = .loading
        guard let channel = await connection.ensureConnected() else {
            guard generation == self.generation else { return }
            phase = .failed(connection.failure?.message ?? "Hôte injoignable.")
            return
        }
        await catalog.startIfNeeded()
        if catalog.view == nil { await catalog.start() }
        guard generation == self.generation else { return }
        guard let provider, let access = provider.accountAccess else {
            if catalog.view == nil, let failure = catalog.failure {
                phase = .failed(failure)
            } else {
                phase = .noAccount
            }
            return
        }
        let client = UsageStatsClient(client: channel)
        do {
            let snapshot = try await client.entitlement(providerId: provider.providerId, accountAccess: access)
            guard generation == self.generation else { return }
            self.snapshot = snapshot
            updatedAt = now()
            phase = .ready
        } catch {
            guard generation == self.generation else { return }
            phase = .failed("Utilisation indisponible : \(UsageLabels.failure(error))")
            return
        }
        guard !isResetting else { return }   // l'action tient ses lectures de statut
        await loadResets(client: client, providerId: provider.providerId, access: access, generation: generation)
    }

    /// Change de fournisseur (plusieurs comptes sur l'hôte) et relit.
    public func select(providerId: String) async {
        guard providerId != provider?.providerId else { return }
        selectedProviderId = providerId
        snapshot = nil
        updatedAt = nil
        resetStatus = nil
        resetIssue = nil
        resetNotice = nil
        resetError = nil
        await refresh()
    }

    // MARK: - Réinitialisations

    /// Lit le statut des réinitialisations puis redemande l'éligibilité au fournisseur (sans elle, le statut ne montre
    /// que les opportunités déjà accordées). Un échec ne masque pas les jauges : il devient `resetIssue` et l'ancien
    /// statut reste affiché.
    private func loadResets(client: UsageStatsClient, providerId: String, access: ProviderAccountAccess,
                            generation: Int) async {
        do {
            var status = try await client.resetStatus(providerId: providerId, accountAccess: access)
            guard generation == self.generation else { return }
            resetStatus = status
            resetIssue = nil
            // Un refus (`granted == false`) ou une limite de débit n'est pas une erreur : le statut lu suffit.
            guard let opportunity = try? await client.requestResetOpportunity(
                providerId: providerId, accountAccess: access, idempotencyKey: UUID().uuidString), opportunity.granted else {
                return
            }
            if let granted = try? await client.resetStatus(providerId: providerId, accountAccess: access) {
                status = granted
            }
            guard generation == self.generation else { return }
            resetStatus = status
        } catch {
            guard generation == self.generation else { return }
            resetIssue = UsageLabels.resetFailure(error)
        }
    }

    /// Consomme une réinitialisation du type donné : `use` puis confirmation par l'historique du type (la consommation
    /// apparaît avec un petit délai côté fournisseur), historique marqué lu et jauges relues. Refusé sans opportunité
    /// disponible ou pendant une autre consommation ; l'échec devient `resetError` sans toucher aux jauges.
    public func useReset(_ type: CodingPlanResetType) async {
        guard !isResetting, let provider, let access = provider.accountAccess,
              let status = resetStatus, !status.opportunities(for: type).isEmpty else { return }
        isResetting = true
        resetNotice = nil
        resetError = nil
        defer { isResetting = false }
        guard let channel = await connection.ensureConnected() else {
            resetError = connection.failure?.message ?? "Hôte injoignable."
            return
        }
        let client = UsageStatsClient(client: channel)
        let baseline = status.latestUsedAt(for: type)
        do {
            try await client.useReset(providerId: provider.providerId, accountAccess: access,
                                      idempotencyKey: UUID().uuidString, type: type)
        } catch {
            resetError = UsageLabels.resetFailure(error)
            // L'envoi a pu partir malgré l'erreur réseau : le statut relit la vérité du fournisseur.
            if let fresh = try? await client.resetStatus(providerId: provider.providerId, accountAccess: access) {
                resetStatus = fresh
            }
            return
        }
        // Confirmation : l'historique du type change quand le fournisseur enregistre la consommation.
        var confirmed = false
        for step in ConfirmationDelays.allCases {
            if step.seconds > 0 { try? await pause(step.seconds) }
            guard let fresh = try? await client.resetStatus(providerId: provider.providerId, accountAccess: access) else { continue }
            resetStatus = fresh
            if fresh.latestUsedAt(for: type) != baseline {
                confirmed = true
                break
            }
        }
        if confirmed, resetStatus?.hasUnreadHistory == true {
            try? await client.markResetHistoryRead(providerId: provider.providerId, accountAccess: access)
        }
        // Les jauges : le quota vient d'être rendu, même si la confirmation traîne.
        if let fresh = try? await client.entitlement(providerId: provider.providerId, accountAccess: access) {
            snapshot = fresh
            updatedAt = now()
        }
        if confirmed {
            resetNotice = UsageLabels.resetDone(type)
        } else {
            resetError = "Réinitialisation envoyée, mais non confirmée par le fournisseur. Actualise."
        }
    }

    /// Espacement des relectures de confirmation, comme l'interface web (un peu plus patiente sur mobile).
    private enum ConfirmationDelays: CaseIterable {
        case immediately, short, medium, long, last
        var seconds: TimeInterval {
            switch self {
            case .immediately: 0
            case .short: 0.3
            case .medium: 0.8
            case .long: 1.6
            case .last: 3
            }
        }
    }
}
