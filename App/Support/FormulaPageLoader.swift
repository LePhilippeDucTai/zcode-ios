import WebKit

enum FormulaPageError: Error {
    case missingResources, processTerminated, emptySnapshot
}

/// Charge la page locale des formules dans un `WKWebView` et attend la fin de la navigation (une seule à la fois).
@MainActor
final class FormulaPageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    /// Appelé quand le processus de la page meurt : la page est rechargée au rendu suivant.
    var onTermination: () -> Void = {}
    /// Seule page écoutée : une page abandonnée (délai dépassé) ne termine pas le chargement de la suivante.
    private weak var current: WKWebView?

    func load(_ webView: WKWebView, file: URL, readAccess: URL) async throws {
        current?.navigationDelegate = nil
        finish(CancellationError())     // chargement précédent abandonné (délai dépassé) : sa suite n'attend plus
        current = webView
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.continuation = continuation
            webView.loadFileURL(file, allowingReadAccessTo: readAccess)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === current else { return }
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard webView === current else { return }
        finish(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard webView === current else { return }
        finish(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === current else { return }
        finish(FormulaPageError.processTerminated)
        onTermination()
    }

    private func finish(_ error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
