import SwiftUI

/// Recherche dans la conversation : champ, compteur « 3/12 », précédent / suivant, « Chercher plus loin ».
struct ChatSearchBar: View {
    @Binding var text: String
    /// « 3/12 », « Aucun résultat », ou `nil` sans requête.
    let counter: String?
    let canMove: Bool
    let canSearchOlder: Bool
    let searchingOlder: Bool
    /// Issue du dernier « Chercher plus loin » (début atteint, limite, échec).
    let olderNote: String?
    let previous: () -> Void
    let next: () -> Void
    let searchOlder: () -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Rechercher dans la conversation", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($focused)
                        .onSubmit(previous)
                        .accessibilityIdentifier("chat-search-field")
                    if let counter {
                        Text(counter)
                            .font(ZCodeTypography.metadata)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .accessibilityIdentifier("chat-search-counter")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                Button(action: previous) { Image(systemName: "chevron.up") }
                    .disabled(!canMove)
                    .accessibilityLabel("Résultat précédent")
                    .accessibilityIdentifier("chat-search-previous")
                Button(action: next) { Image(systemName: "chevron.down") }
                    .disabled(!canMove)
                    .accessibilityLabel("Résultat suivant")
                    .accessibilityIdentifier("chat-search-next")
                Button("Fermer", action: close)
                    .accessibilityIdentifier("chat-search-close")
            }
            if canSearchOlder || olderNote != nil {
                HStack(spacing: 8) {
                    if canSearchOlder {
                        Button(action: searchOlder) {
                            Label("Chercher plus loin", systemImage: "clock.arrow.circlepath")
                        }
                        .disabled(searchingOlder)
                        .accessibilityIdentifier("chat-search-older")
                        if searchingOlder { ProgressView().controlSize(.small) }
                    }
                    if let olderNote { Text(olderNote).foregroundStyle(.secondary) }
                }
                .font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { focused = true }
    }
}
