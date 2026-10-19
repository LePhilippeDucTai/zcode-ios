import UIKit
import WebKit

/// Clé d'une image de formule : même source, même mode, même taille, même couleur, même échelle → même image.
struct FormulaKey: Hashable, Sendable {
    let latex: String
    let display: Bool
    /// Taille du texte autour, en points (KaTeX dessine à 1,21 fois cette taille, comme sur le web).
    let fontSize: CGFloat
    /// Couleur CSS du texte autour, résolue en clair ou en sombre : `rgba(r,g,b,a)`.
    let color: String
    let scale: CGFloat
}

struct RenderedFormula: Sendable {
    let image: UIImage
    /// Hauteur sous la ligne de base, en points (0 pour une formule en bloc).
    let depth: CGFloat
}

enum FormulaResult: Sendable {
    case image(RenderedFormula)
    /// Source refusée par KaTeX (`throwOnError: true`) : source brute en gris, comme le web.
    case failed
    /// Moteur indisponible (page non chargée, capture impossible ou trop longue) : source brute, nouvel essai au
    /// prochain affichage.
    case unavailable
}

/// Rend les formules LaTeX en images avec KaTeX embarqué (`App/Resources/KaTeX`, jamais le réseau) : un seul
/// `WKWebView` hors écran, une formule à la fois dans l'ordre des demandes, images gardées en mémoire.
@MainActor
final class FormulaRenderer {
    static let shared = FormulaRenderer()
    /// Au-delà de ce nombre d'entrées, le cache est vidé d'un coup.
    static let cacheLimit = 600
    /// Au-delà de ce poids d'images décodées, le cache est vidé d'un coup : une image en ligne pèse de l'ordre de 50 à
    /// 100 Ko à l'échelle 3, un bloc large plusieurs Mo.
    static let cacheCostLimit = 32 * 1024 * 1024
    /// Côté maximal de la zone capturée, en points : au-delà (`\rule{500em}{500em}`, `\hspace{2000em}`), la capture
    /// pèserait des centaines de Mo, voire des Go, et iOS pourrait tuer l'app ; la formule est alors refusée
    /// (`.failed`, source en gris). Une formule large légitime (30 sommes en bloc : 2 363 pt mesurés) reste bien en dessous.
    static let maxCaptureSide: CGFloat = 4096
    /// Surface maximale de la capture, en pixels (largeur × hauteur × échelle²) : 16 777 216 px, soit environ 64 Mo en
    /// RGBA. Ferme le cas qu'un plafond par côté laisse passer (formule presque carrée de 4 000 pt de côté : près de
    /// 600 Mo à l'échelle 3) ; au-delà, `.failed` sans capture. Une formule large en une ligne (2 363 × 64 pt :
    /// 1,4 Mpx à l'échelle 3) reste très en dessous.
    static let maxCapturePixels: CGFloat = 16_777_216
    /// Taille de départ de la vue, rétablie après la capture d'une formule plus grande.
    private static let defaultViewSize = CGSize(width: 1024, height: 512)
    /// `true` pour poser la vue sous le contenu de la fenêtre avant de capturer ; `false` : capture sans fenêtre, car
    /// la capture d'une vue posée sous la fenêtre rend une image vide.
    private static let attachesToWindow = false

    /// Durée maximale du rendu d'une formule (JavaScript et capture, page déjà chargée) : au-delà, source brute pour
    /// cette fois (non gardé, nouvel essai à la demande suivante) et formule suivante, pour qu'une capture qui ne
    /// répond jamais ne bloque pas toute la file. Modifiable par les tests.
    var renderTimeout: Duration = .seconds(5)
    /// Durée maximale du chargement de la page (KaTeX et ses polices), à part et bien plus longue : un appareil lent
    /// finit toujours par charger la page, que le délai d'une formule n'abandonne jamais. Au-delà, moteur indisponible.
    static let loadTimeout: Duration = .seconds(30)

    private var cache: [FormulaKey: FormulaResult] = [:]
    /// Poids des images du cache, en octets décodés.
    private var cacheCost = 0
    /// Nombre de captures faites depuis le lancement (lu par les tests : une formule refusée n'est pas capturée).
    private(set) var captureCount = 0
    private var inflight: [FormulaKey: Task<FormulaResult, Never>] = [:]
    private var queueTail: Task<FormulaResult, Never>?
    private var webView: WKWebView?
    private let loader = FormulaPageLoader()
    private var memoryWarning: (any NSObjectProtocol)?

    private init() {
        loader.onTermination = { [weak self] in
            self?.discardWebView()
        }
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearCache() }
        }
    }

    func cached(_ key: FormulaKey) -> FormulaResult? {
        cache[key]
    }

    /// Image d'une formule (du cache, ou rendue après les demandes précédentes). Un échec du moteur n'est pas gardé.
    func render(_ key: FormulaKey) async -> FormulaResult {
        if let hit = cache[key] { return hit }
        if let running = inflight[key] { return await running.value }
        let previous = queueTail
        let task = Task { () -> FormulaResult in
            _ = await previous?.value
            return await self.renderNow(key)
        }
        inflight[key] = task
        queueTail = task
        let result = await task.value
        inflight[key] = nil
        if case .unavailable = result { return result }
        let cost = Self.cost(of: result)
        if cache.count >= Self.cacheLimit || cacheCost + cost > Self.cacheCostLimit { clearCache() }
        cache[key] = result
        cacheCost += cost
        return result
    }

    private func clearCache() {
        cache.removeAll()
        cacheCost = 0
    }

    /// Octets de l'image décodée (0 pour un refus).
    private static func cost(of result: FormulaResult) -> Int {
        guard case .image(let formula) = result, let cgImage = formula.image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// Rendu d'une formule : page chargée (bornée par `loadTimeout`), puis JavaScript et capture (bornés par
    /// `renderTimeout`). Un délai dépassé rend `.unavailable` : source brute non grisée, jamais gardée en cache.
    private func renderNow(_ key: FormulaKey) async -> FormulaResult {
        guard let webView = await loadedWebView() else { return .unavailable }
        guard let result = await bounded(renderTimeout, { await self.draw(key, on: webView) }) else {
            // Capture ou script bloqué : page abandonnée, rechargée au rendu suivant (le travail orphelin ne touche
            // plus à rien, voir les gardes `=== self.webView`).
            if webView === self.webView { discardWebView() }
            return .unavailable
        }
        return result
    }

    /// Page prête, chargée au besoin dans la limite de `loadTimeout` ; `nil` si le chargement échoue ou traîne.
    private func loadedWebView() async -> WKWebView? {
        if webView == nil {
            // Après le délai, la tâche de chargement est annulée : `readyWebView` n'installe alors pas sa page, et le
            // chargement suivant reprend l'ancienne suite (`FormulaPageLoader.load`).
            guard await bounded(Self.loadTimeout, { (try? await self.readyWebView()) != nil }) == true else { return nil }
        }
        return try? await readyWebView()
    }

    /// JavaScript puis capture sur une page chargée.
    private func draw(_ key: FormulaKey, on webView: WKWebView) async -> FormulaResult {
        do {
            let value = try await webView.callAsyncJavaScript(
                "return await renderFormula(latex, display, size, color);",
                arguments: ["latex": key.latex, "display": key.display, "size": Double(key.fontSize), "color": key.color],
                contentWorld: .page)
            guard let box = value as? [String: Any], let ok = box["ok"] as? Bool else { return .unavailable }
            guard ok else { return .failed }
            func number(_ name: String) -> CGFloat { CGFloat((box[name] as? NSNumber)?.doubleValue ?? 0) }
            let rect = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
            guard rect.width >= 1, rect.height >= 1 else { return .failed }
            // Formule démesurée : refusée avant d'agrandir la vue ou de capturer quoi que ce soit.
            guard rect.width <= Self.maxCaptureSide, rect.height <= Self.maxCaptureSide,
                  rect.width * rect.height * key.scale * key.scale <= Self.maxCapturePixels else { return .failed }
            if rect.maxX > webView.bounds.width || rect.maxY > webView.bounds.height {
                webView.frame.size = CGSize(width: max(webView.bounds.width, rect.maxX.rounded(.up)),
                                            height: max(webView.bounds.height, rect.maxY.rounded(.up)))
            }
            defer {
                // Vue rendue à sa taille de départ : une formule large ne la laisse pas énorme pour la session.
                if webView.bounds.size != Self.defaultViewSize { webView.frame.size = Self.defaultViewSize }
            }
            let image = try await capture(webView, rect: rect, scale: key.scale)
            return .image(RenderedFormula(image: image, depth: key.display ? 0 : max(0, rect.maxY - number("baseline"))))
        } catch {
            // Page rechargée au prochain rendu ; une page plus récente (après un délai dépassé) n'est pas touchée.
            if webView === self.webView { discardWebView() }
            return .unavailable
        }
    }

    /// `work` borné à `timeout` ; `nil` si le délai passe d'abord. Course non structurée : un groupe de tâches
    /// attendrait un travail bloqué. Le perdant est annulé (minuterie comprise : aucune tâche ne dort pour rien).
    private func bounded<T: Sendable>(_ timeout: Duration, _ work: @escaping @MainActor () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let outcome = FormulaOutcome(continuation)
            outcome.tasks.append(Task { outcome.resume(with: await work()) })
            outcome.tasks.append(Task {
                try? await Task.sleep(for: timeout)
                outcome.resume(with: nil)
            })
        }
    }

    private func readyWebView() async throws -> WKWebView {
        if let webView {
            if Self.attachesToWindow, webView.window == nil { attach(webView) }
            return webView
        }
        guard let directory = Bundle.main.url(forResource: "KaTeX", withExtension: nil) else {
            throw FormulaPageError.missingResources
        }
        let view = WKWebView(frame: CGRect(origin: .zero, size: Self.defaultViewSize), configuration: WKWebViewConfiguration())
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        if Self.attachesToWindow { attach(view) }
        try await loader.load(view, file: directory.appending(path: "formula.html"), readAccess: directory)
        // Chargement terminé après un délai dépassé : cette page n'est plus la bonne (une autre a pu la remplacer).
        guard !Task.isCancelled else { throw CancellationError() }
        webView = view
        return view
    }

    /// Abandonne la page courante : elle est rechargée au rendu suivant, et ses événements tardifs sont ignorés.
    private func discardWebView() {
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    /// Sous tout le contenu de la fenêtre active : invisible (couverte par l'app), mais peinte par WebKit.
    private func attach(_ view: WKWebView) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        window?.insertSubview(view, at: 0)
    }

    private func capture(_ webView: WKWebView, rect: CGRect, scale: CGFloat) async throws -> UIImage {
        captureCount += 1
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.afterScreenUpdates = true
        // La capture sort à l'échelle de l'écran de la vue : largeur demandée corrigée si l'échelle voulue diffère.
        let viewScale = webView.window?.windowScene?.screen.scale ?? scale
        if viewScale != scale { configuration.snapshotWidth = NSNumber(value: Double(rect.width * scale / viewScale)) }
        let snapshot = try await webView.takeSnapshot(configuration: configuration)
        guard let cgImage = snapshot.cgImage else { throw FormulaPageError.emptySnapshot }
        // Taille en points = zone mesurée, quelle que soit la densité réelle de la capture.
        return UIImage(cgImage: cgImage, scale: CGFloat(cgImage.width) / rect.width, orientation: .up)
    }
}

/// Issue d'une course entre un travail et un délai : seule la première arrivée est rendue, puis tout est annulé.
@MainActor
private final class FormulaOutcome<T: Sendable> {
    private var continuation: CheckedContinuation<T?, Never>?
    var tasks: [Task<Void, Never>] = []

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(with result: T?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
        tasks.forEach { $0.cancel() }
        tasks = []
    }
}
