import SwiftUI
import ZCodeAppCore
import ZCodeV4

/// Utilisation du Coding Plan de l'hôte : une jauge par fenêtre (5 heures, semaine, outils, MCP), réinitialisations et
/// abonnement. Les chiffres viennent de l'hôte (`usage-stats`), qui interroge lui-même Z.ai / BigModel.
struct UsageView: View {
    let host: Host
    @Environment(AppModel.self) private var model
    /// Type dont la consommation vient d'être demandée (dialogue de confirmation ouvert).
    @State private var confirmingReset: CodingPlanResetType?

    var body: some View {
        let usage = model.usage(for: host)
        List {
            if usage.providers.count > 1 {
                accountSection(usage)
            }
            switch usage.phase {
            case .idle, .loading:
                if let snapshot = usage.snapshot {
                    content(snapshot, usage)
                } else {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Lecture de l'utilisation…").foregroundStyle(.secondary)
                        }
                    }
                }
            case .ready:
                if let snapshot = usage.snapshot { content(snapshot, usage) }
            case .noAccount:
                Section {
                    ContentUnavailableView(
                        "Aucun compte Coding Plan", systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("L'hôte n'a aucun fournisseur par compte Z.ai / BigModel. Connecte le Coding Plan dans ZCode sur l'hôte, puis actualise.")
                    )
                }
            case .failed(let message):
                Section {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("usage-error")
                    Button("Réessayer") { Task { await usage.refresh() } }
                }
            }
        }
        .navigationTitle("Utilisation")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await usage.refresh() }
                } label: {
                    if usage.phase == .loading {
                        ProgressView()
                    } else {
                        Label("Actualiser", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(usage.phase == .loading)
                .accessibilityIdentifier("usage-refresh")
            }
        }
        .task { await usage.loadIfNeeded() }
        .refreshable { await usage.refresh() }
        .confirmationDialog(
            confirmingReset.map(UsageLabels.resetConfirmationTitle) ?? "",
            isPresented: Binding(
                get: { confirmingReset != nil },
                set: { shown in if !shown { confirmingReset = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Réinitialiser", role: .destructive) {
                let type = confirmingReset
                confirmingReset = nil
                if let type { Task { await usage.useReset(type) } }
            }
            .accessibilityIdentifier("usage-reset-confirm")
            Button("Annuler", role: .cancel) { confirmingReset = nil }
        } message: {
            if let type = confirmingReset {
                Text(UsageLabels.resetConfirmationMessage(
                    type, count: usage.resetStatus?.opportunities(for: type).count ?? 0))
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func accountSection(_ usage: UsageModel) -> some View {
        Section("Compte") {
            Picker("Compte", selection: Binding(
                get: { usage.provider?.providerId ?? "" },
                set: { id in Task { await usage.select(providerId: id) } }
            )) {
                ForEach(usage.providers) { provider in
                    Text(provider.name).tag(provider.providerId)
                }
            }
            .accessibilityIdentifier("usage-account")
        }
    }

    @ViewBuilder
    private func content(_ snapshot: UsageEntitlementSnapshot, _ usage: UsageModel) -> some View {
        Section {
            planRow(snapshot, usage)
            if snapshot.balanceHidden {
                Label("Le fournisseur demande de ne pas afficher ce solde.", systemImage: "eye.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        if snapshot.isEmpty {
            Section {
                Text(UsageLabels.unavailable(snapshot.unavailableReason))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("usage-unavailable")
            }
        } else {
            Section("Limites") {
                ForEach(Array(snapshot.displayedLimits.enumerated()), id: \.offset) { _, limit in
                    UsageLimitRow(limit: limit)
                }
            }
        }
        resetSection(usage)
        if !snapshot.subscriptions.isEmpty {
            Section("Abonnement") {
                ForEach(Array(snapshot.subscriptions.enumerated()), id: \.offset) { _, subscription in
                    subscriptionRow(subscription)
                }
            }
        }
        Section {
            EmptyView()
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let updatedAt = usage.updatedAt {
                    Text("Mis à jour à \(updatedAt.formatted(date: .omitted, time: .shortened)).")
                }
                Text("Chiffres lus par ZCode sur l'hôte auprès du fournisseur ; les pourcentages sont ceux qu'il annonce.")
            }
        }
    }

    private func planRow(_ snapshot: UsageEntitlementSnapshot, _ usage: UsageModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(UsageLabels.planTitle(snapshot) ?? "Coding Plan")
                    .font(.headline)
                Spacer()
                if let level = snapshot.level {
                    Text(level.uppercased())
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }
            }
            if let providerName = snapshot.providerName ?? usage.provider?.name {
                Text(providerName).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage-plan")
    }

    // MARK: - Réinitialisations

    /// Identifiant d'accessibilité d'un type de réinitialisation (même vocabulaire que les fenêtres de limites).
    private static func resetId(_ type: CodingPlanResetType) -> String {
        type == .week ? "weekly" : "five-hours"
    }

    /// Réinitialisations accordées et non consommées : une ligne par type qui en a, le bouton qui en consomme une,
    /// l'avancement et le résultat de la dernière consommation. Masquée sans rien à montrer (comme l'interface web).
    @ViewBuilder
    private func resetSection(_ usage: UsageModel) -> some View {
        let rows = CodingPlanResetType.allCases.filter { !(usage.resetStatus?.opportunities(for: $0).isEmpty ?? true) }
        if !rows.isEmpty || usage.isResetting || usage.resetNotice != nil
            || usage.resetError != nil || usage.resetIssue != nil {
            Section {
                ForEach(rows, id: \.rawValue) { type in
                    resetRow(usage, type: type)
                }
                if usage.isResetting {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Réinitialisation en cours…").foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("usage-reset-progress")
                }
                if let notice = usage.resetNotice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("usage-reset-notice")
                }
                if let error = usage.resetError {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("usage-reset-error")
                }
                if let issue = usage.resetIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("usage-reset-issue")
                }
            } header: {
                Text("Réinitialisations")
            } footer: {
                Text("Chaque réinitialisation rend le quota correspondant ; celles qui ne servent pas expirent.")
            }
        }
    }

    /// Une ligne de réinitialisation : titre de la fenêtre, nombre disponibles, échéance la plus proche et bouton
    /// « Réinitialiser » (avec confirmation : la ressource est comptée).
    private func resetRow(_ usage: UsageModel, type: CodingPlanResetType) -> some View {
        let opportunities = usage.resetStatus?.opportunities(for: type) ?? []
        let count = opportunities.count
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(UsageLabels.resetTitle(type)).font(.headline)
                Text(UsageLabels.resetOpportunities(count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let soonest = opportunities.map(\.expireAt).min() {
                    HStack(spacing: 4) {
                        Text(count == 1 ? "Expire " : "La plus proche expire ")
                        Text(soonest, format: .relative(presentation: .named))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("usage-reset-\(Self.resetId(type))")
            .accessibilityValue(UsageLabels.resetOpportunities(count))
            Spacer()
            if usage.isResetting {
                ProgressView()
            } else {
                Button("Réinitialiser") { confirmingReset = type }
                    .buttonStyle(.bordered)
                    .disabled(count == 0)
                    .accessibilityLabel("Réinitialiser \(UsageLabels.resetTitle(type).lowercased())")
                    .accessibilityIdentifier("usage-reset-action-\(Self.resetId(type))")
            }
        }
        .padding(.vertical, 2)
    }

    private func subscriptionRow(_ subscription: UsageSubscriptionDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(subscription.productName).font(.headline)
                Spacer()
                if let cycle = UsageLabels.billingCycle(subscription.billingCycle) {
                    Text(cycle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let renew = subscription.renewTime {
                Text("Renouvellement le \(renew.formatted(date: .long, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let expire = subscription.expireTime {
                Text("Expire le \(expire.formatted(date: .long, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Une limite : jauge du **restant** (pleine = rien consommé), part restante, montants et prochaine réinitialisation.
struct UsageLimitRow: View {
    let limit: UsageQuotaLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(UsageLabels.title(limit.window)).font(.headline)
                Spacer()
                Text(remainingText)
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(gaugeColor)
            }
            ProgressView(value: 1 - limit.usedFraction)
                .tint(gaugeColor)
            HStack(alignment: .firstTextBaseline) {
                if let amount = amountText {
                    Text(amount)
                }
                Spacer()
                if let reset = resetText {
                    Text(reset)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if let detail = UsageLabels.detail(limit) {
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage-limit-\(windowId)")
        .accessibilityValue(remainingText)
    }

    private var windowId: String {
        switch limit.window {
        case .fiveHours: "five-hours"
        case .weekly: "weekly"
        case .monthlyTools: "tools"
        case .mcp: "mcp"
        case .other: "other"
        }
    }

    /// Part restante, un chiffre après la virgule seulement sous 10 % (comme l'interface web).
    private var remainingText: String {
        guard let remaining = limit.remainingPercentage else { return "—" }
        let digits = remaining >= 10 ? 0 : 1
        return "\(remaining.formatted(.number.precision(.fractionLength(0...digits))))\u{202F}% restants"
    }

    private var amountText: String? {
        let unit = UsageLabels.unit(limit)
        if let used = limit.used, let total = limit.total {
            return "\(used.formatted()) / \(total.formatted()) \(unit)"
        }
        if let remaining = limit.remaining {
            return "\(remaining.formatted()) \(unit) restants"
        }
        return nil
    }

    private var resetText: String? {
        guard let date = limit.nextReset else { return nil }
        if UsageLabels.showsResetTime(limit.window) {
            if Calendar.current.isDateInToday(date) {
                return "Réinitialisation à \(date.formatted(date: .omitted, time: .shortened))"
            }
            return "Réinitialisation le \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Réinitialisation le \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Vert tant qu'il reste la moitié, orange jusqu'à 20 %, rouge ensuite ; neutre sans pourcentage.
    private var gaugeColor: Color {
        guard let remaining = limit.remainingPercentage else { return .accentColor }
        if remaining >= 50 { return .green }
        if remaining >= 20 { return .orange }
        return .red
    }
}
