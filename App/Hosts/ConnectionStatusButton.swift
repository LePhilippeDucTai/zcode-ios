import SwiftUI
import ZCodeAppCore

/// Pastille d'état de connexion dans la barre de la fiche de l'hôte ; toucher ⇒ bulle de détail (lot 13J).
struct ConnectionStatusButton: View {
    let connection: HostConnection
    @State private var showingDetail = false

    var body: some View {
        Button { showingDetail = true } label: { icon }
            .accessibilityLabel("État de la connexion")
            .accessibilityValue(stateLabel)                  // lu par les parcours UI (« Connecté »)
            .accessibilityIdentifier("connection-status")
            .popover(isPresented: $showingDetail) {
                ConnectionDetail(connection: connection)
                    .presentationCompactAdaptation(.popover)
            }
    }

    @ViewBuilder private var icon: some View {
        switch connection.state {
        case .idle: Image(systemName: "circle").foregroundStyle(.secondary)
        case .connecting: ProgressView()
        case .connected:
            if connection.versionWarning != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var stateLabel: String {
        switch connection.state {
        case .idle: "Non connecté"
        case .connecting: "Connexion"
        case .connected: "Connecté"
        case .failed: "Échec"
        }
    }
}

/// Contenu de la bulle : état, version, avertissement, échec et « Réessayer ».
private struct ConnectionDetail: View {
    let connection: HostConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch connection.state {
            case .idle: Text("Non connecté")
            case .connecting: Text("Connexion…")
            case .connected: Label("Connecté", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let failure): Label(failure.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            if let version = connection.serverInfo?.version {
                Text("ZCode \(version)").font(.callout).foregroundStyle(.secondary)
            }
            if let warning = connection.versionWarning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            if case .failed = connection.state {
                Button("Réessayer") { Task { await connection.connect() } }
                    .accessibilityIdentifier("connection-retry")
            }
        }
        .padding()
        .frame(minWidth: 220, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-detail")
    }
}
