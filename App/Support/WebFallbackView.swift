import SwiftUI
import WebKit

/// Interface web officielle de ZCode, pour toute fonction pas encore native.
struct WebFallbackView: View {
    let url: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    WebPage(url: url)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("Token manquant", systemImage: "key.slash",
                                           description: Text("Modifie l'hôte pour saisir à nouveau son token."))
                }
            }
            .navigationTitle("Interface web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}

private struct WebPage: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Rien n'est conservé entre deux ouvertures : l'URL porte le token, la session web repart de zéro.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
