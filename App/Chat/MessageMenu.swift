import SwiftUI
import ZCodeAppCore

/// « Repartir d'ici » (lot 13C) : fourni par `ChatView` ; l'entrée n'apparaît que sur une réponse que l'hôte marque
/// `canFork`. Toujours égal à lui-même (comme `AttachmentLoader`) : passer par l'environnement n'invalide aucune
/// cellule de la conversation.
struct MessageForkAction: Sendable, Equatable {
    var fork: (@MainActor @Sendable (_ rowId: Int) -> Void)?

    static func == (lhs: MessageForkAction, rhs: MessageForkAction) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var messageFork = MessageForkAction()
}

/// Appui long sur un message ou une réponse : copier ou partager le texte (Markdown source).
private struct MessageMenu: ViewModifier {
    let text: String
    let rowId: Int
    let forkable: Bool
    @Environment(\.messageFork) private var messageFork

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("Copier", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("message-copy")
            ShareLink(item: text) {
                Label("Partager", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("message-share")
            if forkable, let fork = messageFork.fork {
                Button {
                    fork(rowId)
                } label: {
                    Label("Repartir d'ici", systemImage: "arrow.triangle.branch")
                }
                .accessibilityIdentifier("message-fork")
            }
        }
    }
}

extension View {
    /// Menu contextuel d'un message ; sans texte (`ChatItem.copyableText == nil`) ou sans ligne (guide en attente),
    /// aucun menu. `forkable` : l'hôte permet de repartir de cette réponse (`actions.canFork`).
    @ViewBuilder func messageMenu(text: String?, rowId: Int?, forkable: Bool = false) -> some View {
        if let text, let rowId {
            modifier(MessageMenu(text: text, rowId: rowId, forkable: forkable))
        } else {
            self
        }
    }
}
