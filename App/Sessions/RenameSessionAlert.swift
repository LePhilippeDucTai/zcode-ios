import SwiftUI
import ZCodeAppCore

/// Session à renommer et son titre actuel (prérempli).
struct RenameTarget: Identifiable, Equatable {
    let sessionId: String
    let currentTitle: String?
    var id: String { sessionId }
}

/// Alerte de renommage d'une session, partagée par la conversation et la liste.
private struct RenameSessionAlert: ViewModifier {
    let host: Host
    let workspace: String
    @Binding var target: RenameTarget?
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .alert("Renommer la session", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                   presenting: target) { target in
                TextField("Titre", text: $text)
                    .accessibilityIdentifier("rename-field")
                Button("Annuler", role: .cancel) {}
                // Le texte est lu au toucher : la fermeture de l'alerte remet `target` (donc `text`) à zéro.
                Button("Renommer") {
                    let typed = text
                    Task { await rename(target, typed: typed) }
                }
                .accessibilityIdentifier("rename-submit")
            }
            .onChange(of: target) { text = target?.currentTitle ?? "" }
            .alert("Renommage impossible", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    private func rename(_ target: RenameTarget, typed: String) async {
        guard let title = SessionTitle.normalized(typed, current: target.currentTitle) else { return }
        do {
            try await model.renameSession(host: host, workspace: workspace, sessionId: target.sessionId, title: title)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

extension View {
    func renameSessionAlert(host: Host, workspace: String, target: Binding<RenameTarget?>) -> some View {
        modifier(RenameSessionAlert(host: host, workspace: workspace, target: target))
    }
}
