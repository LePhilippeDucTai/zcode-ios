import SwiftUI
import ZCodeAppCore

/// Prompts favoris (communs à tous les hôtes) : insérer, ajouter, modifier, supprimer, réordonner.
struct PromptFavoritesView: View {
    let store: PromptStore
    /// Toucher un favori l'insère dans le brouillon et ferme la feuille.
    let insert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Editing?

    struct Editing: Identifiable {
        /// `nil` : nouveau favori.
        let favoriteId: UUID?
        var title: String
        var text: String
        var id: String { favoriteId?.uuidString ?? "nouveau" }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.favorites) { favorite in
                    Button {
                        insert(favorite.text)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(favorite.title).font(ZCodeTypography.body)
                            Text(favorite.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Modifier") {
                            editing = Editing(favoriteId: favorite.id, title: favorite.title, text: favorite.text)
                        }
                        .tint(.blue)
                    }
                }
                .onDelete { offsets in offsets.map { store.favorites[$0].id }.forEach(store.remove) }
                .onMove { store.move(from: $0, to: $1) }
            }
            .accessibilityIdentifier("prompt-favorites-list")
            .overlay {
                if store.favorites.isEmpty {
                    ContentUnavailableView("Aucun favori", systemImage: "star",
                                           description: Text("Ajoute un prompt, ou enregistre un brouillon depuis le menu « + »."))
                }
            }
            .navigationTitle("Prompts favoris")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = Editing(favoriteId: nil, title: "", text: "") } label: {
                        Label("Ajouter", systemImage: "plus")
                    }
                    .accessibilityIdentifier("prompt-favorite-add")
                }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            .sheet(item: $editing) { current in
                PromptEditorView(editing: current) { title, text in
                    if let id = current.favoriteId {
                        store.update(id, title: title, text: text)
                    } else {
                        store.add(title: title, text: text)
                    }
                }
            }
        }
    }
}

/// Titre et texte d'un favori.
private struct PromptEditorView: View {
    @State var editing: PromptFavoritesView.Editing
    let save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Titre (première ligne si vide)", text: $editing.title)
                    .accessibilityIdentifier("prompt-favorite-title")
                TextEditor(text: $editing.text)
                    .frame(minHeight: 160)
                    .accessibilityIdentifier("prompt-favorite-text")
            }
            .navigationTitle(editing.favoriteId == nil ? "Nouveau favori" : "Modifier le favori")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        save(editing.title, editing.text)
                        dismiss()
                    }
                    .disabled(editing.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("prompt-favorite-save")
                }
            }
        }
    }
}
