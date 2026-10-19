import XCTest
import UIKit

final class ZCodeUITests: XCTestCase {
    /// Projet de test annoncé par l'hôte (`TEST_RUNNER_ZCODE_SEED_WORKSPACE`, chemin absolu ; son parent est le home
    /// de l'hôte) et un sous-dossier qui contient un `README.md` (`TEST_RUNNER_ZCODE_SEED_SUBFOLDER`, par défaut
    /// `zcode-ios` : un clone de ce dépôt).
    private static let workspace = ProcessInfo.processInfo.environment["ZCODE_SEED_WORKSPACE"] ?? ""
    private static let subfolder = ProcessInfo.processInfo.environment["ZCODE_SEED_SUBFOLDER"] ?? "zcode-ios"
    private static var workspaceName: String { (workspace as NSString).lastPathComponent }
    /// Projet du second hôte (`TEST_RUNNER_ZCODE_SEED2_WORKSPACE`), pour `testParcoursDeuxHotes`.
    private static let workspace2 = ProcessInfo.processInfo.environment["ZCODE_SEED2_WORKSPACE"] ?? ""
    private static var home: String { (workspace as NSString).deletingLastPathComponent }

    override func setUp() {
        continueAfterFailure = false
    }

    func testLancement() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    /// Lance l'app avec un hôte injecté et un état vierge. Ignoré si `ZCODE_SEED_URL`/`ZCODE_SEED_TOKEN` sont absents.
    /// `secondHost: true` exige aussi `ZCODE_SEED2_*` et l'ajoute comme « Steam (test) ».
    private func launchSeeded(secondHost: Bool = false) throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["ZCODE_SEED_URL"], let token = environment["ZCODE_SEED_TOKEN"] else {
            throw XCTSkip("ZCODE_SEED_URL et ZCODE_SEED_TOKEN absents")
        }
        guard !Self.workspace.isEmpty else { throw XCTSkip("ZCODE_SEED_WORKSPACE absent") }
        var launchEnvironment = [
            "ZCODE_RESET": "1", "ZCODE_SEED_NAME": "Mac (test)", "ZCODE_SEED_URL": url, "ZCODE_SEED_TOKEN": token,
        ]
        if secondHost {
            guard let url2 = environment["ZCODE_SEED2_URL"], let token2 = environment["ZCODE_SEED2_TOKEN"] else {
                throw XCTSkip("ZCODE_SEED2_URL et ZCODE_SEED2_TOKEN absents")
            }
            launchEnvironment["ZCODE_SEED2_NAME"] = "Steam (test)"
            launchEnvironment["ZCODE_SEED2_URL"] = url2
            launchEnvironment["ZCODE_SEED2_TOKEN"] = token2
            guard !Self.workspace2.isEmpty else { throw XCTSkip("ZCODE_SEED2_WORKSPACE absent") }
        }
        let app = XCUIApplication()
        app.launchEnvironment = launchEnvironment
        app.launch()
        return app
    }

    /// Attend « Connecté » sur l'écran de l'hôte courant.
    private func waitConnected(_ app: XCUIApplication, timeout: TimeInterval = 30) {
        let status = app.descendants(matching: .any)["connection-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Connecté"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: timeout), .completed, "hôte connecté par le tailnet")
    }

    /// Deux retours en arrière : sessions → hôte → liste des hôtes.
    private func backToHosts(_ app: XCUIApplication) {
        for _ in 0..<2 {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
        }
    }

    /// Ouvre l'hôte injecté puis le projet ~/claude ; renvoie la liste des sessions.
    private func openWorkspace(_ app: XCUIApplication) throws -> XCUIElement {
        keep(app, "1-hotes")

        app.staticTexts["Mac (test)"].tap()
        let status = app.descendants(matching: .any)["connection-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Connecté"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [connected], timeout: 30), .completed, "connexion au Mac par le tailnet")
        keep(app, "2-hote")

        let workspace = app.descendants(matching: .any)["workspace-\(Self.workspace)"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        let list = app.collectionViews["sessions-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        return list
    }

    /// Parcours réel : hôte injecté → connexion au Mac par le tailnet → projet ~/claude → sessions → conversation.
    /// Exige `TEST_RUNNER_ZCODE_SEED_URL` et `TEST_RUNNER_ZCODE_SEED_TOKEN` (sinon ignoré).
    func testParcoursHoteProjetSessions() throws {
        let app = try launchSeeded()
        let list = try openWorkspace(app)
        XCTAssertTrue(list.cells.firstMatch.waitForExistence(timeout: 30), "sessions de ~/claude affichées")
        keep(app, "3-sessions")

        list.cells.firstMatch.tap()
        let chat = app.scrollViews["chat-list"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        let answer = app.descendants(matching: .any).matching(identifier: "assistant-text").firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 30), "réponse de l'agent affichée")
        // Le conteneur `.contain` n'a pas de libellé (VoiceOver lirait le Markdown brut) : le texte est dans ses enfants.
        XCTAssertTrue(answer.staticTexts.firstMatch.exists, "texte de la réponse lu par l'accessibilité (enfants du conteneur)")
        XCTAssertTrue(app.textFields["composer-field"].exists || app.textViews["composer-field"].exists)
        keep(app, "4-conversation")
    }

    /// Parcours réel (lot 13F, un prompt GLM) : nouvelle session → commande Bash forcée → durée de la carte d'outil
    /// (obligatoire : prouve que l'identifiant reste exposé malgré le libellé du HStack parent), heure du message en
    /// relatif → exacte → relatif, en-tête des durées → session archivée. Les conversations de ~/claude peuvent toutes
    /// être archivées : le parcours crée la sienne.
    func testParcoursHeuresEtDurees() throws {
        let app = try launchSeeded()
        let list = try openWorkspace(app)
        app.buttons["Nouvelle session"].tap()
        let field = app.descendants(matching: .any)["composer-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Exécute la commande shell `echo PONG` avec l'outil Bash, puis réponds seulement PONG.")
        app.buttons["composer-send"].tap()

        let duration = app.descendants(matching: .any).matching(identifier: "tool-duration").firstMatch
        XCTAssertTrue(duration.waitForExistence(timeout: 120), "durée de la carte d'outil interrogeable")
        let answer = app.descendants(matching: .any).matching(identifier: "assistant-text").firstMatch
        let pong = answer.staticTexts.containing(NSPredicate(format: "label CONTAINS 'PONG'")).firstMatch
        XCTAssertTrue(pong.waitForExistence(timeout: 120), "réponse PONG de GLM")
        dismissKeyboard(app)
        keep(app, "13f-carte")
        // L'identifiant est exposé, mais SwiftUI le porte sur l'élément fusionné de la ligne (libellé VoiceOver
        // « Bash, echo PONG, Terminé, < 1 s ») : la durée est donc la fin de ce libellé.
        let durationEnd = ", (< 1 s|[0-9]+,[0-9] s|[0-9]+ s|[0-9]+ min [0-9]{2} s|[0-9]+ h [0-9]{2} min)$"
        XCTAssertTrue(NSPredicate(format: "label MATCHES %@", ".*" + durationEnd).evaluate(with: duration),
                      "durée de carte (\(app.descendants(matching: .any).matching(identifier: "tool-duration").count) éléments) : \(duration.label)")

        let times = app.descendants(matching: .any).matching(identifier: "message-time")
        XCTAssertTrue(times.firstMatch.waitForExistence(timeout: 30), "au moins une heure de message")
        let label = try XCTUnwrap(times.allElementsBoundByIndex.last { $0.isHittable }, "une heure visible")
        let relative = NSPredicate(format: "label MATCHES %@", "^(à l'instant|il y a [0-9]+ min)$")
        XCTAssertTrue(relative.evaluate(with: label), "heure relative : \(label.label)")
        let before = label.label
        keep(app, "13f-heure-relative")

        label.tap()
        let exact = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", ".+, [0-9]{2}:[0-9]{2}:[0-9]{2}$"),
                                              object: label)
        XCTAssertEqual(XCTWaiter.wait(for: [exact], timeout: 3), .completed, "heure exacte après un toucher")
        keep(app, "13f-heure-exacte")
        label.tap()
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", before), object: label)
        XCTAssertEqual(XCTWaiter.wait(for: [back], timeout: 3), .completed, "retour au relatif")

        let header = app.descendants(matching: .any)["session-durations"]
        XCTAssertTrue(header.waitForExistence(timeout: 5), "en-tête des durées")
        XCTAssertTrue(header.label.contains("de travail"), "en-tête : \(header.label)")
        keep(app, "13f-en-tete")

        app.buttons["chat-menu"].tap()
        app.buttons["Archiver la conversation"].tap()
        XCTAssertTrue(list.waitForExistence(timeout: 15), "retour à la liste après archivage")
    }

    /// Parcours réel complet : nouvelle session → prompt GLM → « PONG » affiché → session supprimée (ménage sur le Mac).
    /// Coûte un prompt GLM.
    func testParcoursChatPong() throws {
        let app = try launchSeeded()
        let list = try openWorkspace(app)
        app.buttons["Nouvelle session"].tap()
        let field = app.descendants(matching: .any)["composer-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Réponds uniquement par le mot PONG, sans rien d'autre.")
        app.buttons["composer-send"].tap()
        let answer = app.descendants(matching: .any).matching(identifier: "assistant-text").firstMatch
        let pong = answer.staticTexts.containing(NSPredicate(format: "label CONTAINS 'PONG'")).firstMatch
        XCTAssertTrue(pong.waitForExistence(timeout: 120), "réponse PONG de GLM")
        keep(app, "5-pong")
        dismissKeyboard(app)
        app.buttons["chat-menu"].tap()
        app.buttons["Archiver la conversation"].tap()
        XCTAssertTrue(list.waitForExistence(timeout: 15), "retour à la liste après suppression")
    }

    /// Parcours réel : nouvelle session → PONG → sous-titre hôte · dossier → renommage (barre puis liste) → session
    /// archivée. Coûte un prompt GLM.
    func testParcoursFenetreSession() throws {
        let app = try launchSeeded()
        let list = try openWorkspace(app)
        app.buttons["Nouvelle session"].tap()
        let field = app.descendants(matching: .any)["composer-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Réponds uniquement par le mot PONG, sans rien d'autre.")
        app.buttons["composer-send"].tap()
        let answer = app.descendants(matching: .any).matching(identifier: "assistant-text").firstMatch
        let pong = answer.staticTexts.containing(NSPredicate(format: "label CONTAINS 'PONG'")).firstMatch
        XCTAssertTrue(pong.waitForExistence(timeout: 120), "réponse PONG de GLM")
        // Titre maison de la barre : titre en libellé, « hôte · dossier » en valeur.
        let barTitle = app.buttons["chat-title"]
        let location = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "Mac (test) · "),
                                                 object: barTitle)
        XCTAssertEqual(XCTWaiter.wait(for: [location], timeout: 10), .completed, "hôte et dossier sous le titre")
        keep(app, "13-fenetre-session")
        dismissKeyboard(app)
        app.buttons["chat-usage"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["usage-limit-five-hours"].waitForExistence(timeout: 20),
                      "utilisation ouverte depuis la session")
        keep(app, "14-utilisation-session")
        app.navigationBars.buttons["OK"].firstMatch.tap()
        let title = "Renommage UI \(Int(Date().timeIntervalSince1970) % 100_000)"
        app.buttons["chat-menu"].tap()
        app.buttons["chat-rename"].tap()
        // Dans une alerte, les éléments sont cherchés sous `alerts` (les identifiants n'y sont pas toujours exposés).
        let alert = app.alerts["Renommer la session"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let rename = alert.textFields.firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        // Le champ est prérempli avec le titre actuel : on l'efface avant de taper le nouveau. Toucher le bord droit
        // place le curseur en fin de texte (au centre, il restait en tête : le titre était inséré devant l'ancien).
        rename.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let current = (rename.value as? String) ?? ""
        rename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + title)
        XCTAssertEqual(rename.value as? String, title, "champ de renommage remplacé par le nouveau titre")
        alert.buttons["Renommer"].firstMatch.tap()
        // Avec `.toolbarTitleMenu`, le titre peut être exposé en bouton : on cherche tout type d'élément de la barre.
        let renamed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", title), object: barTitle)
        XCTAssertEqual(XCTWaiter.wait(for: [renamed], timeout: 15), .completed, "nouveau titre dans la barre")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(list.staticTexts[title].waitForExistence(timeout: 15), "nouveau titre dans la liste")
        list.staticTexts[title].tap()
        app.buttons["chat-menu"].tap()
        app.buttons["Archiver la conversation"].tap()
        XCTAssertTrue(list.waitForExistence(timeout: 15), "retour à la liste après archivage")
    }

    /// Parcours réel : nouvelle session → demande d'écrire un fichier → autorisation(s) accordée(s) depuis le dock →
    /// tour terminé → session supprimée. Coûte un prompt GLM ; laisse `~/claude/.zcode-check/` sur le Mac (à supprimer).
    func testParcoursApprobation() throws {
        let app = try launchSeeded()
        let list = try openWorkspace(app)
        app.buttons["Nouvelle session"].tap()
        let field = app.descendants(matching: .any)["composer-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Crée le fichier .zcode-check/ui-approbation.txt contenant le texte OK avec ton outil d'écriture, puis confirme en une phrase.")
        app.buttons["composer-send"].tap()
        let dock = app.descendants(matching: .any)["interaction-dock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 120), "demande d'autorisation affichée dans le dock")
        keep(app, "6-autorisation")
        // Une demande par outil (dossier, écriture) : chacune est accordée une fois, jusqu'à la fin du tour.
        let allow = app.buttons["interaction-option-allowOnce"]
        let send = app.buttons["composer-send"]
        var granted = 0
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            // `isHittable` plutôt que `exists` : le dock peut disparaître entre le test et le toucher.
            if allow.isHittable {
                allow.tap()
                granted += 1
            } else if granted > 0, send.exists, !dock.exists {
                break
            }
            sleep(1)
        }
        XCTAssertGreaterThan(granted, 0, "au moins une autorisation accordée depuis le dock")
        XCTAssertTrue(send.exists, "tour terminé, composeur revenu")
        keep(app, "7-apres-autorisation")
        app.buttons["chat-menu"].tap()
        app.buttons["Archiver la conversation"].tap()
        XCTAssertTrue(list.waitForExistence(timeout: 15), "retour à la liste après suppression")
    }

    /// Parcours réel sans prompt : projet ~/claude → Fichiers → zcode_ios → README.md ; puis Modifications (~/claude
    /// n'est pas un dépôt Git). Exige `TEST_RUNNER_ZCODE_SEED_URL` et `TEST_RUNNER_ZCODE_SEED_TOKEN` (sinon ignoré).
    func testParcoursFichiers() throws {
        let app = try launchSeeded()
        _ = try openWorkspace(app)
        app.buttons["workspace-files"].tap()
        XCTAssertTrue(app.collectionViews["files-list"].waitForExistence(timeout: 10))
        let project = app.descendants(matching: .any)["file-entry-\(Self.subfolder)"]
        XCTAssertTrue(project.waitForExistence(timeout: 15), "dossier zcode_ios listé")
        project.tap()
        let readme = app.descendants(matching: .any)["file-entry-README.md"]
        XCTAssertTrue(readme.waitForExistence(timeout: 15), "README.md listé")
        readme.tap()
        XCTAssertTrue(app.descendants(matching: .any)["file-content"].waitForExistence(timeout: 15))
        let title = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "ZCode iOS")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "README rendu")
        keep(app, "6-fichier")

        for _ in 0..<3 {                                             // README → zcode_ios → Fichiers → sessions
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
        }
        app.buttons["workspace-changes"].tap()
        XCTAssertTrue(app.staticTexts["Pas un dépôt Git"].waitForExistence(timeout: 15), "~/claude hors dépôt")
        keep(app, "7-modifications")
    }

    /// Parcours réel sans prompt : hôte → « Utilisation du Coding Plan » → jauges des fenêtres de 5 h et de la semaine (plan
    /// GLM du compte) et du MCP officiel, puis actualisation, puis réinitialisations : ligne de la fenêtre de 5 h,
    /// dialogue de confirmation ouvert puis annulé — **rien n'est consommé** (seul « Réinitialiser » du dialogue envoie).
    /// Exige `TEST_RUNNER_ZCODE_SEED_URL` et `TEST_RUNNER_ZCODE_SEED_TOKEN` (sinon ignoré).
    func testParcoursUtilisation() throws {
        let app = try launchSeeded()
        app.staticTexts["Mac (test)"].tap()
        waitConnected(app)

        let link = app.descendants(matching: .any)["host-usage"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        XCTAssertTrue(app.descendants(matching: .any)["usage-plan"].waitForExistence(timeout: 30), "plan affiché")
        let fiveHours = app.descendants(matching: .any)["usage-limit-five-hours"]
        XCTAssertTrue(fiveHours.waitForExistence(timeout: 10), "fenêtre de 5 heures affichée")
        XCTAssertTrue((fiveHours.value as? String)?.contains("restants") == true, "part restante annoncée")
        XCTAssertTrue(app.descendants(matching: .any)["usage-limit-weekly"].exists, "semaine affichée")
        XCTAssertTrue(app.descendants(matching: .any)["usage-limit-mcp"].exists, "MCP officiel affiché")
        XCTAssertTrue(app.staticTexts["GLM Coding Max"].firstMatch.exists, "nom commercial du plan")
        keep(app, "8-utilisation")

        app.buttons["usage-refresh"].tap()
        XCTAssertTrue(fiveHours.waitForExistence(timeout: 30), "jauge toujours là après actualisation")

        // Réinitialisations : ligne de la fenêtre de 5 heures, dialogue de confirmation ouvert puis annulé — le
        // parcours ne consomme rien (le bouton seul n'envoie rien, seuls « Réinitialiser » du dialogue le ferait).
        let resetRow = app.descendants(matching: .any)["usage-reset-five-hours"]
        XCTAssertTrue(resetRow.waitForExistence(timeout: 30), "réinitialisations de la fenêtre de 5 heures affichées")
        XCTAssertTrue((resetRow.value as? String)?.contains("réinitialisation") == true, "nombre disponible annoncé")
        app.buttons["usage-reset-action-five-hours"].tap()
        let confirm = app.buttons["usage-reset-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "dialogue de confirmation")
        keep(app, "13e-reset-dialogue")
        // Annulation sans consommation. Le bouton « Annuler » du dialogue système n'est pas toujours exposé comme
        // Button à XCUITest : on le cherche partout, sinon un toucher au-dessus de la feuille ferme le dialogue
        // (aucun envoi sans le bouton « Réinitialiser » du dialogue lui-même).
        let cancel = app.descendants(matching: .any)["Annuler"]
        if cancel.waitForExistence(timeout: 5) {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        }
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10), "dialogue fermé sans consommation")
        XCTAssertTrue(app.descendants(matching: .any)["usage-reset-five-hours"].waitForExistence(timeout: 10),
                      "ligne toujours là après annulation")
    }

    /// Parcours réel sans prompt : mode par défaut « Autonome » sur l'hôte → nouvelle session (brouillon) dont le
    /// composeur affiche « Autonome » et le quota des 5 h → suppression du brouillon → recherche dans la liste. Exige
    /// `TEST_RUNNER_ZCODE_SEED_URL` et `TEST_RUNNER_ZCODE_SEED_TOKEN` (sinon ignoré).
    func testParcoursListeEtReglages() throws {
        let app = try launchSeeded()
        app.staticTexts["Mac (test)"].tap()
        waitConnected(app)
        let picker = app.buttons["host-default-mode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        app.buttons["Autonome"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "sessions créées depuis cet iPhone"))
            .firstMatch.waitForExistence(timeout: 5))
        keep(app, "13a-mode-par-defaut")

        let workspace = app.descendants(matching: .any)["workspace-\(Self.workspace)"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        XCTAssertTrue(app.collectionViews["sessions-list"].waitForExistence(timeout: 10))
        app.buttons["Nouvelle session"].tap()
        let mode = app.buttons["composer-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 15))
        let autonomous = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Autonome"), object: mode)
        XCTAssertEqual(XCTWaiter.wait(for: [autonomous], timeout: 15), .completed, "mode demandé à la création")
        XCTAssertTrue(app.buttons["composer-quota"].waitForExistence(timeout: 15), "quota des 5 h dans le composeur")
        keep(app, "13a-composeur")

        app.navigationBars.buttons.element(boundBy: 0).tap()                         // retour à la liste
        let draft = app.staticTexts["Nouvelle session"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.swipeLeft()
        app.buttons["Supprimer"].tap()
        XCTAssertTrue(draft.waitForNonExistence(timeout: 10), "brouillon supprimé sur l'hôte")

        let search = app.searchFields.firstMatch
        if !search.exists { app.collectionViews["sessions-list"].swipeDown() }      // champ révélé en tirant
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("zzz-introuvable")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "zzz-introuvable"))
            .firstMatch.waitForExistence(timeout: 5), "état vide de la recherche")
        keep(app, "13a-recherche")
    }

    /// Parcours réel : réponse avec un bloc de code bash → « Copier » (collé dans le composeur : la commande seule,
    /// sans les balises du bloc) → menus contextuels → recherche « pong » → session archivée.
    /// Coûte un prompt GLM.
    func testParcoursLectureConversation() throws {
        let app = try launchSeeded()
        let list = try openWorkspace(app)
        app.buttons["Nouvelle session"].tap()
        let field = app.descendants(matching: .any)["composer-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Réponds uniquement par un bloc de code bash qui contient la commande echo PONG, sans rien d'autre.")
        app.buttons["composer-send"].tap()
        let copy = app.buttons["code-copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 120), "bloc de code de la réponse avec son bouton Copier")
        keep(app, "13b-bloc-de-code")
        dismissKeyboard(app)
        copy.tap()
        let copied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Copié"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [copied], timeout: 3), .completed, "coche « Copié »")

        // Collage par le menu d'édition (geste de l'utilisateur : pas d'alerte de collage).
        field.tap()
        field.press(forDuration: 1.2)
        let paste = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["Coller", "Paste"])).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "menu d'édition avec « Coller »")
        paste.tap()
        let pasted = (field.value as? String) ?? ""
        XCTAssertTrue(pasted.contains("echo PONG"), "commande collée : \(pasted)")
        XCTAssertFalse(pasted.contains("```"), "sans les balises du bloc")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: pasted.count))   // brouillon vidé
        dismissKeyboard(app)

        // Menu de la réponse : la bulle envoyée porte le même menu, donc on colle ce qu'il a copié. Le Markdown source de
        // la réponse contient « ``` » ; le prompt envoyé n'en contient pas.
        let answer = app.descendants(matching: .any).matching(identifier: "assistant-text").firstMatch
        answer.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["message-copy"].waitForExistence(timeout: 5), "un menu contextuel Copier / Partager")
        XCTAssertTrue(app.buttons["message-share"].exists, "menu contextuel : Partager")
        XCTAssertFalse(app.buttons["Repartir d'ici"].exists, "accroche 13C non branchée")
        keep(app, "13b-menu-contextuel")
        app.buttons["message-copy"].tap()                                              // copie et referme le menu
        field.tap()
        field.press(forDuration: 1.2)
        let pasteAnswer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["Coller", "Paste"])).firstMatch
        XCTAssertTrue(pasteAnswer.waitForExistence(timeout: 5), "menu d'édition avec « Coller »")
        pasteAnswer.tap()
        let copiedByMenu = (field.value as? String) ?? ""
        XCTAssertTrue(copiedByMenu.contains("```"), "le menu copie la réponse (Markdown source), pas le prompt : \(copiedByMenu)")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: copiedByMenu.count))   // brouillon vidé
        dismissKeyboard(app)
        // Bulle du message envoyé : le menu est posé sur le `Text` même (pas sur un conteneur).
        let question = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Réponds uniquement")).firstMatch
        question.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["message-copy"].waitForExistence(timeout: 5), "menu contextuel du message envoyé")
        app.buttons["message-copy"].tap()

        app.buttons["chat-menu"].tap()
        app.buttons["chat-search"].tap()
        let search = app.textFields["chat-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        if !search.hasFocus { search.tap() }
        search.typeText("pong")
        let counter = app.staticTexts["chat-search-counter"]
        let found = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "[0-9]+/[0-9]+"),
                                              object: counter)
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 5), .completed, "compteur « n/N »")
        app.buttons["chat-search-previous"].tap()
        keep(app, "13b-recherche")
        app.buttons["chat-search-close"].tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        dismissKeyboard(app)
        app.buttons["chat-menu"].tap()
        app.buttons["Archiver la conversation"].tap()
        XCTAssertTrue(list.waitForExistence(timeout: 15), "retour à la liste après archivage")
    }

    /// Parcours réel sans prompt : image collée dans le composeur d'une nouvelle session → vignette touchée →
    /// visionneuse plein écran → fermée → brouillon supprimé sur l'hôte.
    func testParcoursImagePleinEcran() throws {
        let app = try launchSeeded()
        _ = try openWorkspace(app)
        UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        app.buttons["Nouvelle session"].tap()
        let attach = app.buttons["composer-attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 20))
        attach.tap()
        app.buttons["Coller l'image"].tap()
        allowPasteIfAsked(app)
        let tile = app.descendants(matching: .any)["composer-attachment-0"]
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "vignette dans le composeur")
        tile.tap()
        let viewer = app.descendants(matching: .any)["image-viewer"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "visionneuse plein écran")
        XCTAssertTrue(app.buttons["image-viewer-share"].waitForExistence(timeout: 20), "image affichée, partage proposé")
        keep(app, "13b-plein-ecran")
        app.buttons["image-viewer-close"].tap()
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 5))

        app.navigationBars.buttons.element(boundBy: 0).tap()                         // retour à la liste
        let draft = app.staticTexts["Nouvelle session"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.swipeLeft()
        app.buttons["Supprimer"].tap()
        XCTAssertTrue(draft.waitForNonExistence(timeout: 10), "brouillon supprimé sur l'hôte")
    }

    /// Parcours réel sans prompt : nouvelle session → « / » → panneau (commande de l'hôte, sous-agent intégré) → filtre
    /// « pla » → `/plan` inséré → envoi = bascule en mode plan sans rien envoyer → skill insérée en jeton `$nom` →
    /// « Fermer » → brouillon supprimé sur l'hôte.
    func testParcoursPanneauSlash() throws {
        let app = try launchSeeded()
        _ = try openWorkspace(app)
        app.buttons["Nouvelle session"].tap()
        let field = app.descendants(matching: .any)["composer-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("/")
        let panel = app.descendants(matching: .any)["slash-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "panneau « / » ouvert")
        XCTAssertTrue(app.buttons["slash-row-command-goal"].waitForExistence(timeout: 20), "commande /goal de l'hôte")
        keep(app, "13c-panneau")
        // Les sous-agents sont en dernière section et la liste est paresseuse : défiler le panneau jusqu'à Explore.
        let explore = app.buttons["slash-row-subagent-Explore"]
        for _ in 0..<8 where !explore.exists { panel.swipeUp() }
        XCTAssertTrue(explore.waitForExistence(timeout: 5), "sous-agent intégré Explore")
        for _ in 0..<8 where !app.buttons["slash-row-command-goal"].exists { panel.swipeDown() }

        field.typeText("pla")
        let plan = app.buttons["slash-row-command-plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5), "filtre « pla »")
        XCTAssertFalse(app.buttons["slash-row-command-goal"].exists, "/goal écarté par le filtre")
        plan.tap()
        XCTAssertEqual(field.value as? String, "/plan ", "mot remplacé, espace ajoutée")
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "panneau fermé par l'espace")
        app.buttons["composer-send"].tap()
        let planned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Mode plan"),
                                                object: app.buttons["composer-mode"])
        XCTAssertEqual(XCTWaiter.wait(for: [planned], timeout: 5), .completed, "/plan seul : mode plan, rien d'envoyé")
        // Rien n'est parti vers le modèle : ni bulle utilisateur « /plan », ni réponse, et le brouillon est vidé.
        sleep(2)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "/plan")).firstMatch.exists,
                       "aucun message utilisateur « /plan » envoyé")
        XCTAssertFalse(app.descendants(matching: .any)["assistant-text"].exists, "aucune réponse du modèle")
        XCTAssertFalse(app.buttons["composer-stop"].exists, "aucun tour en cours")
        keep(app, "13c-mode-plan")

        if !field.hasFocus { field.tap() }
        field.typeText("/")
        let skill = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "slash-row-skill-")).firstMatch
        if skill.waitForExistence(timeout: 10) {
            skill.tap()
            XCTAssertTrue((field.value as? String ?? "").hasPrefix("$"), "skill insérée en jeton $nom")
            keep(app, "13c-jeton-skill")
        } else {
            XCTFail("aucune skill dans le panneau (ni ~/.zcode/skills ni plugin)")
        }
        let typed = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed.count) + "/")
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        app.buttons["slash-close"].tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "« Fermer »")
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        dismissKeyboard(app)

        app.navigationBars.buttons.element(boundBy: 0).tap()                         // retour à la liste
        let draft = app.staticTexts["Nouvelle session"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.swipeLeft()
        app.buttons["Supprimer"].tap()
        XCTAssertTrue(draft.waitForNonExistence(timeout: 10), "brouillon supprimé sur l'hôte")
    }

    /// Parcours réel : PONG → appui long sur la réponse → « Repartir d'ici » → session enfant (marqueur en tête) →
    /// enfant puis parent archivés. Coûte un prompt GLM.
    func testParcoursRepartirDIci() throws {
        let app = try launchSeeded()
        let list = try openWorkspace(app)
        app.buttons["Nouvelle session"].tap()
        let field = app.descendants(matching: .any)["composer-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Réponds uniquement par le mot PONG, sans rien d'autre.")
        app.buttons["composer-send"].tap()
        let answer = app.descendants(matching: .any).matching(identifier: "assistant-text").firstMatch
        let pong = answer.staticTexts.containing(NSPredicate(format: "label CONTAINS 'PONG'")).firstMatch
        XCTAssertTrue(pong.waitForExistence(timeout: 120), "réponse PONG de GLM")
        dismissKeyboard(app)
        let fork = app.buttons["message-fork"]
        // L'entrée n'apparaît qu'une fois la réponse figée (`canFork`) : quelques essais, menu refermé entre deux.
        var offered = false
        for _ in 0..<5 where !offered {
            answer.press(forDuration: 1.2)
            offered = fork.waitForExistence(timeout: 3)
            if !offered {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
                sleep(2)
            }
        }
        XCTAssertTrue(offered, "« Repartir d'ici » une fois la réponse figée")
        keep(app, "13c-menu-fork")
        fork.tap()
        let notice = app.staticTexts["Conversation dérivée d'une autre session"]
        XCTAssertTrue(notice.waitForExistence(timeout: 30), "session enfant ouverte, marqueur en tête")
        keep(app, "13c-enfant")
        app.buttons["chat-menu"].tap()
        app.buttons["Archiver la conversation"].tap()                                // enfant : retour au parent
        XCTAssertTrue(app.buttons["chat-menu"].waitForExistence(timeout: 15))
        XCTAssertTrue(pong.waitForExistence(timeout: 15), "retour à la conversation d'origine")
        app.buttons["chat-menu"].tap()
        app.buttons["Archiver la conversation"].tap()
        XCTAssertTrue(list.waitForExistence(timeout: 15), "retour à la liste après archivage")
    }

    /// Alerte système de collage (l'app lit le presse-papiers rempli par le test) : « Autoriser le collage ».
    private func allowPasteIfAsked(_ app: XCUIApplication) {
        let labels = ["Autoriser le collage", "Allow Paste"]
        for candidate in [XCUIApplication(bundleIdentifier: "com.apple.springboard"), app] {
            let allow = candidate.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            if allow.waitForExistence(timeout: 3) {
                allow.tap()
                return
            }
        }
    }

    /// Parcours réel d'un Goal : nouvelle session → bouton « Goal » → objectif trivial → bandeau → « Atteint » → détail →
    /// session supprimée. Coûte ≈ 2 à 4 appels GLM (un tour et une vérification par itération).
    func testParcoursGoal() throws {
        let app = try launchSeeded()
        let list = try openWorkspace(app)
        app.buttons["Nouvelle session"].tap()
        let goalButton = app.buttons["composer-goal"]
        XCTAssertTrue(goalButton.waitForExistence(timeout: 20))
        goalButton.tap()
        let objective = app.descendants(matching: .any)["goal-objective"]
        XCTAssertTrue(objective.waitForExistence(timeout: 10))
        objective.tap()
        objective.typeText("Réponds uniquement par le mot OK. Le Goal est atteint dès que tu as répondu OK.")
        app.buttons["goal-start"].tap()
        let banner = app.descendants(matching: .any)["goal-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "bandeau du Goal affiché")
        keep(app, "8-goal")
        let status = app.descendants(matching: .any)["goal-status"]
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Atteint"), object: status)
        if XCTWaiter.wait(for: [reached], timeout: 180) != .completed {
            if app.buttons["goal-pause"].exists { app.buttons["goal-pause"].tap() }   // arrêter la dépense avant d'échouer
            XCTFail("Goal non atteint en 180 s")
        }
        keep(app, "9-goal-atteint")
        banner.tap()
        XCTAssertTrue(app.descendants(matching: .any)["goal-detail"].waitForExistence(timeout: 10))
        keep(app, "10-goal-detail")
        app.buttons["OK"].tap()
        app.buttons["chat-menu"].tap()
        app.buttons["Archiver la conversation"].tap()
        XCTAssertTrue(list.waitForExistence(timeout: 15), "retour à la liste après suppression")
    }

    /// Parcours réel sans prompt : bascule Mac ↔ Steam Machine — la seconde connexion ne coupe pas la première.
    /// Exige en plus `TEST_RUNNER_ZCODE_SEED2_URL` et `TEST_RUNNER_ZCODE_SEED2_TOKEN` (sinon ignoré).
    func testParcoursDeuxHotes() throws {
        let app = try launchSeeded(secondHost: true)
        keep(app, "11-deux-hotes")

        // Steam Machine d'abord : connexion par le tailnet, projet du second hôte, sessions.
        app.staticTexts["Steam (test)"].tap()
        waitConnected(app)
        let steamWorkspace = app.descendants(matching: .any)["workspace-\(Self.workspace2)"]
        XCTAssertTrue(steamWorkspace.waitForExistence(timeout: 10))
        steamWorkspace.tap()
        XCTAssertTrue(app.collectionViews["sessions-list"].waitForExistence(timeout: 10))
        keep(app, "12-steam-sessions")
        backToHosts(app)

        // Puis le Mac : connecté, sessions visibles pendant que la Steam Machine reste ouverte.
        app.staticTexts["Mac (test)"].tap()
        waitConnected(app)
        let macWorkspace = app.descendants(matching: .any)["workspace-\(Self.workspace)"]
        XCTAssertTrue(macWorkspace.waitForExistence(timeout: 10))
        macWorkspace.tap()
        XCTAssertTrue(app.collectionViews["sessions-list"].waitForExistence(timeout: 10))
        backToHosts(app)

        // Retour à la Steam Machine : encore connectée.
        app.staticTexts["Steam (test)"].tap()
        waitConnected(app)
    }

    /// Bouton d'une confirmation (feuille d'actions ou alerte) : même libellé que le bouton qui l'a ouverte, dont on
    /// écarte l'identifiant.
    private func confirmationButton(_ app: XCUIApplication, _ label: String, excluding trigger: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", label, trigger)).firstMatch
    }

    /// Remplace le texte d'un champ prérempli : curseur en fin de texte (bord droit), effacement, saisie.
    private func replaceText(_ field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    /// Ligne « État » du détail d'un plugin (`LabeledContent` : libellé et valeur réunis ou séparés selon iOS).
    private func state(_ app: XCUIApplication, _ value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(label == %@ AND value == %@) OR label == %@ OR label == %@", "État", value, "État, \(value)", value))
            .firstMatch
    }

    /// Parcours réel sans prompt : projet ~/claude → Extensions → Sous-agents → création d'un agent de projet
    /// `ios-ui-<5 chiffres>`, modification, suppression ; puis portée Utilisateur : Explore (intégré) en lecture seule.
    /// Écrit dans le vrai projet `~/claude/.zcode/agents/` le temps du parcours (ménage : `CLAUDE.md`). Exige
    /// `TEST_RUNNER_ZCODE_SEED_URL` et `TEST_RUNNER_ZCODE_SEED_TOKEN` (sinon ignoré).
    func testParcoursSousAgent() throws {
        let app = try launchSeeded()
        _ = try openWorkspace(app)
        let extensions = app.buttons["workspace-extensions"]
        XCTAssertTrue(extensions.waitForExistence(timeout: 10))
        extensions.tap()
        let target = app.staticTexts["extensions-target"]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        XCTAssertTrue(target.label.contains("Projet claude"), "cible en tête : \(target.label)")
        app.segmentedControls["extensions-segment"].buttons["Sous-agents"].tap()
        XCTAssertTrue(app.collectionViews["subagents-list"].waitForExistence(timeout: 10))

        // Création. Les champs multilignes d'abord (Retour y insère un saut de ligne), le nom en dernier : la touche
        // Retour de ce champ d'une ligne referme le clavier.
        let name = String(format: "ios-ui-%05d", Int(Date().timeIntervalSince1970) % 100_000)
        let create = app.buttons["subagent-new"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 30), .completed, "liste lue, création possible")
        create.tap()
        let description = app.descendants(matching: .any)["subagent-description"]
        XCTAssertTrue(description.waitForExistence(timeout: 10))
        description.tap()
        description.typeText("Sous-agent de test UI")
        let prompt = app.textViews["subagent-prompt"]
        prompt.tap()
        prompt.typeText("Réponds uniquement PONG.")
        let nameField = app.textFields["subagent-name"]
        if !nameField.exists { app.collectionViews["subagent-editor"].swipeDown() }   // retour en haut du formulaire
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(name + "\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "clavier refermé par Retour")
        // Premier modèle proposé : le menu du sélecteur liste « Modèle de la session » puis les modèles du catalogue.
        let modelPicker = app.buttons["subagent-model"]
        modelPicker.tap()
        let menu = app.collectionViews.containing(NSPredicate(format: "label == %@", "Modèle de la session")).firstMatch
        let firstModel = menu.buttons.element(boundBy: 1)
        XCTAssertTrue(firstModel.waitForExistence(timeout: 10), "modèles du catalogue proposés")
        let chosen = firstModel.label
        firstModel.tap()
        let picked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", chosen), object: modelPicker)
        XCTAssertEqual(XCTWaiter.wait(for: [picked], timeout: 5), .completed, "modèle \(chosen) choisi")
        let save = app.buttons["subagent-save"]
        for _ in 0..<4 where !save.exists { app.collectionViews["subagent-editor"].swipeUp() }   // bas du formulaire
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled, "formulaire complet")
        save.tap()
        let row = app.descendants(matching: .any)["subagent-row-\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "sous-agent créé dans la liste")
        keep(app, "ext-1-sous-agent-cree")

        // Modification de la description depuis le détail.
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["subagent-detail"].waitForExistence(timeout: 10))
        app.buttons["subagent-edit"].tap()
        let editedDescription = app.descendants(matching: .any)["subagent-description"]
        XCTAssertTrue(editedDescription.waitForExistence(timeout: 10))
        replaceText(editedDescription, with: "Sous-agent de test UI, modifié")
        app.textFields["subagent-name"].tap()
        app.textFields["subagent-name"].typeText("\n")                        // Retour : clavier refermé
        let saveEdit = app.buttons["subagent-save"]
        for _ in 0..<4 where !saveEdit.exists { app.collectionViews["subagent-editor"].swipeUp() }
        saveEdit.tap()
        XCTAssertTrue(app.staticTexts["Sous-agent de test UI, modifié"].waitForExistence(timeout: 30),
                      "description modifiée affichée")

        // Suppression depuis le détail : retour à la liste, ligne disparue.
        app.buttons["subagent-delete"].tap()
        let confirmDelete = confirmationButton(app, "Supprimer", excluding: "subagent-delete")
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 30), "sous-agent supprimé")

        // Portée Utilisateur : Explore, intégré, sans interrupteur ni « Modifier ».
        app.buttons["extensions-scope"].tap()
        app.buttons["Utilisateur"].firstMatch.tap()
        let userTarget = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", "Utilisateur"),
                                                   object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [userTarget], timeout: 10), .completed, "cible : portée Utilisateur")
        // Les agents des plugins officiels précèdent « Intégrés » : la recherche amène Explore à l'écran.
        let search = app.searchFields.firstMatch
        if !search.exists { app.collectionViews["subagents-list"].swipeDown() }      // champ révélé en tirant
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Explore")
        let explore = app.descendants(matching: .any)["subagent-row-Explore"]
        XCTAssertTrue(explore.waitForExistence(timeout: 30), "Explore dans « Intégrés »")
        XCTAssertTrue(app.staticTexts["Intégrés"].exists, "section « Intégrés »")
        XCTAssertFalse(app.descendants(matching: .any)["subagent-enabled-Explore"].exists, "Explore sans interrupteur")
        explore.tap()
        XCTAssertTrue(app.descendants(matching: .any)["subagent-detail"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["subagent-edit"].exists, "Explore sans « Modifier »")
        XCTAssertFalse(app.buttons["subagent-delete"].exists, "Explore sans « Supprimer »")
        keep(app, "ext-1-explore-lecture-seule")
    }

    /// Parcours réel sans prompt : hôte → Extensions (Utilisateur) → Plugins → source jetable ajoutée (vérifiée) →
    /// plugin `zcode-ios-probe` installé, configuré, désactivé, désinstallé → source retirée. Installe pour l'utilisateur
    /// sur le Mac le temps du parcours (ménage : `CLAUDE.md`). Exige `TEST_RUNNER_ZCODE_SEED_URL`,
    /// `TEST_RUNNER_ZCODE_SEED_TOKEN` et `TEST_RUNNER_ZCODE_PLUGIN_SOURCE` (dossier de `Probe/make-plugin-marketplace.sh`
    /// sur le Mac), sinon ignoré.
    func testParcoursPlugin() throws {
        guard let source = ProcessInfo.processInfo.environment["ZCODE_PLUGIN_SOURCE"], !source.isEmpty else {
            throw XCTSkip("ZCODE_PLUGIN_SOURCE absent")
        }
        let pluginId = "zcode-ios-probe@zcode-ios-probe-market"
        let marketplaceId = "zcode-ios-probe-market"
        let app = try launchSeeded()
        app.staticTexts["Mac (test)"].tap()
        waitConnected(app)
        let extensions = app.descendants(matching: .any)["host-extensions"]
        XCTAssertTrue(extensions.waitForExistence(timeout: 10))
        extensions.tap()
        app.segmentedControls["extensions-segment"].buttons["Plugins"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["plugins-host-note"].waitForExistence(timeout: 30))
        let catalog = app.buttons["plugins-catalog"]
        XCTAssertTrue(catalog.waitForExistence(timeout: 30), "aperçu des plugins lu")

        // Source jetable : vérifiée par l'hôte, puis ajoutée.
        app.buttons["plugins-sources"].tap()
        let add = app.buttons["sources-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let field = app.textFields["source-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(source + "\n")                                         // Retour : clavier refermé
        app.buttons["source-validate"].tap()
        let validation = app.descendants(matching: .any).matching(identifier: "source-validation").firstMatch
        XCTAssertTrue(validation.waitForExistence(timeout: 60), "source vérifiée par l'hôte")
        XCTAssertTrue(app.staticTexts["Source valide"].firstMatch.exists, "« Source valide »")
        app.buttons["source-submit"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 120), "feuille d'ajout fermée sur un succès")
        let sourceRow = app.descendants(matching: .any)["source-row-\(marketplaceId)"]
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 30), "source ajoutée")

        // Plugin trouvé dans le catalogue par son nom.
        app.navigationBars.buttons.element(boundBy: 0).tap()                         // retour aux plugins
        XCTAssertTrue(catalog.waitForExistence(timeout: 10))
        catalog.tap()
        XCTAssertTrue(app.collectionViews["plugins-catalog-list"].waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        if !search.exists { app.collectionViews["plugins-catalog-list"].swipeDown() }   // champ révélé en tirant
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("zcode-ios-probe")
        let catalogRow = app.collectionViews["plugins-catalog-list"].descendants(matching: .any)["plugin-row-\(pluginId)"]
        XCTAssertTrue(catalogRow.waitForExistence(timeout: 10), "plugin jetable au catalogue")
        catalogRow.tap()

        // Installation, après la mise en garde.
        let install = app.buttons["plugin-install"]
        XCTAssertTrue(install.waitForExistence(timeout: 30))
        install.tap()
        let confirmInstall = confirmationButton(app, "Installer", excluding: "plugin-install")
        XCTAssertTrue(confirmInstall.waitForExistence(timeout: 5), "mise en garde avant installation")
        confirmInstall.tap()
        let enabledToggle = app.switches["plugin-enabled"]
        XCTAssertTrue(enabledToggle.waitForExistence(timeout: 120), "plugin installé")
        let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: enabledToggle)
        XCTAssertEqual(XCTWaiter.wait(for: [on], timeout: 30), .completed, "plugin activé")
        XCTAssertTrue(state(app, "Activé").waitForExistence(timeout: 10), "état « Activé »")
        keep(app, "ext-2-plugin-installe")

        // Configuration de l'option non sensible `label`.
        let configure = app.buttons["plugin-configure"]
        XCTAssertTrue(configure.waitForExistence(timeout: 30), "options du plugin lues")
        let configurable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: configure)
        XCTAssertEqual(XCTWaiter.wait(for: [configurable], timeout: 30), .completed)
        configure.tap()
        let label = app.textFields["plugin-config-label"]
        XCTAssertTrue(label.waitForExistence(timeout: 10))
        replaceText(label, with: "ui\n")                                      // Retour : clavier refermé
        app.buttons["plugin-config-save"].tap()
        XCTAssertTrue(label.waitForNonExistence(timeout: 60), "configuration enregistrée, feuille fermée")

        // Désactivation.
        let toggleEnabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: enabledToggle)
        XCTAssertEqual(XCTWaiter.wait(for: [toggleEnabled], timeout: 30), .completed)
        enabledToggle.switches.firstMatch.tap()
        let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: enabledToggle)
        XCTAssertEqual(XCTWaiter.wait(for: [off], timeout: 60), .completed, "plugin désactivé")
        XCTAssertTrue(state(app, "Désactivé").waitForExistence(timeout: 10), "état « Désactivé »")

        // Désinstallation : le plugin quitte « Installés ».
        let uninstall = app.buttons["plugin-uninstall"]
        let uninstallable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: uninstall)
        XCTAssertEqual(XCTWaiter.wait(for: [uninstallable], timeout: 30), .completed)
        uninstall.tap()
        let confirmUninstall = confirmationButton(app, "Désinstaller", excluding: "plugin-uninstall")
        XCTAssertTrue(confirmUninstall.waitForExistence(timeout: 5))
        confirmUninstall.tap()
        XCTAssertTrue(enabledToggle.waitForNonExistence(timeout: 120), "plugin désinstallé")
        app.navigationBars.buttons.element(boundBy: 0).tap()                         // détail → catalogue
        // La recherche du catalogue est restée active et masque la barre de navigation : on la referme d'abord.
        let closeSearch = app.buttons.matching(NSPredicate(format: "label IN %@", ["fermer", "Fermer", "Annuler", "Cancel"]))
            .firstMatch
        if closeSearch.waitForExistence(timeout: 3) { closeSearch.tap() }
        let backToPlugins = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backToPlugins.waitForExistence(timeout: 5))
        backToPlugins.tap()                                                          // catalogue → plugins
        let pluginsList = app.collectionViews["plugins-list"]
        XCTAssertTrue(pluginsList.waitForExistence(timeout: 10))
        XCTAssertTrue(pluginsList.descendants(matching: .any)["plugin-row-\(pluginId)"].waitForNonExistence(timeout: 10),
                      "plus dans « Installés »")

        // Retrait de la source jetable.
        app.buttons["plugins-sources"].tap()
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 10))
        sourceRow.swipeLeft()
        let remove = app.buttons["source-remove-\(marketplaceId)"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        let confirmRemove = confirmationButton(app, "Retirer", excluding: "source-remove-\(marketplaceId)")
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 5))
        confirmRemove.tap()
        XCTAssertTrue(sourceRow.waitForNonExistence(timeout: 60), "source retirée")
    }

    /// Parcours réel (lot 13D, aucun prompt) : ouvre la session de support « Lister fichiers zcode_ios/host via
    /// sous-agent Explore » (laissée sur le Mac, jamais archivée), « Voir le fil » sur la carte Agent, fil de l'enfant
    /// en lecture seule (ni composeur ni dock), retour au parent.
    func testParcoursFilSousAgent() throws {
        let app = try launchSeeded()
        let list = try openWorkspace(app)
        let title = "Lister fichiers zcode_ios/host via sous-agent Explore"
        let row = app.staticTexts[title].firstMatch
        if !row.waitForExistence(timeout: 10) {
            let search = app.searchFields.firstMatch
            if !search.exists { list.swipeDown() }                                   // champ révélé en tirant
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("sous-agent Explore")
        }
        XCTAssertTrue(row.waitForExistence(timeout: 20), "session de support du lot 13D présente sur le Mac")
        row.tap()
        let chat = app.descendants(matching: .any)["chat-list"]
        XCTAssertTrue(chat.waitForExistence(timeout: 20))

        let open = app.buttons["subagent-open"].firstMatch
        var tries = 0
        while !open.exists && tries < 8 { chat.swipeUp(); tries += 1 }
        XCTAssertTrue(open.waitForExistence(timeout: 30), "carte Agent avec « Voir le fil »")
        keep(app, "13d-carte")
        open.tap()
        XCTAssertTrue(chat.waitForExistence(timeout: 20))
        // Lecture seule : ni composeur ni dock.
        XCTAssertFalse(app.descendants(matching: .any)["composer-field"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["interaction-dock"].exists)
        let answer = app.descendants(matching: .any).matching(identifier: "assistant-text").firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 30), "le fil de l'enfant a au moins une réponse")
        keep(app, "13d-fil-enfant")
        app.navigationBars.buttons.element(boundBy: 0).tap()            // retour au parent
        XCTAssertTrue(open.waitForExistence(timeout: 10))
    }

    /// Parcours réel (lot 13I, aucun prompt) : même session de support que `testParcoursFilSousAgent`. Parent :
    /// groupe « réflexion + carte Agent » replié (la carte Agent reste visible), déplié (réflexions visibles), replié ;
    /// pastille `composer-quota`. Fil de l'enfant (lecture seule) : groupe de deux commandes Bash et trois réflexions,
    /// déplier/replier, puis recherche de « maxdepth » (seulement dans la 2e commande, carte cachée) ⇒ groupe déplié
    /// et carte visible.
    func testParcoursGroupeOutils() throws {
        let app = try launchSeeded()
        let list = try openWorkspace(app)
        let title = "Lister fichiers zcode_ios/host via sous-agent Explore"
        let row = app.staticTexts[title].firstMatch
        if !row.waitForExistence(timeout: 10) {
            let search = app.searchFields.firstMatch
            if !search.exists { list.swipeDown() }                                   // champ révélé en tirant
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("sous-agent Explore")
        }
        XCTAssertTrue(row.waitForExistence(timeout: 20), "session de support du lot 13D présente sur le Mac")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat-list"].waitForExistence(timeout: 20))

        let groups = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "tool-group-"))
        let reasonings = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Réflexion"))
        let parentGroup = groups.firstMatch
        XCTAssertTrue(parentGroup.waitForExistence(timeout: 30), "groupe d'outils dans le parent")
        expectValue(parentGroup, "replié")
        XCTAssertTrue(app.buttons["subagent-open"].firstMatch.exists, "carte Agent visible sous le groupe replié")
        XCTAssertEqual(reasonings.count, 0, "réflexions repliées dans le groupe")
        XCTAssertTrue(app.buttons["composer-quota"].waitForExistence(timeout: 15), "anneaux de quota au composeur")
        keep(app, "13i-parent-replie")
        parentGroup.tap()
        expectValue(parentGroup, "déplié")
        XCTAssertTrue(reasonings.firstMatch.waitForExistence(timeout: 5), "réflexion visible une fois déplié")
        XCTAssertTrue(app.buttons["subagent-open"].firstMatch.exists)
        keep(app, "13i-parent-deplie")
        parentGroup.tap()
        expectValue(parentGroup, "replié")

        // Fil de l'enfant : deux commandes Bash cachées sous le groupe replié.
        app.buttons["subagent-open"].firstMatch.tap()
        let bashCards = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Bash, "))
        let childGroup = groups.firstMatch
        XCTAssertTrue(childGroup.waitForExistence(timeout: 30), "groupe d'outils dans le fil de l'enfant")
        expectValue(childGroup, "replié")
        XCTAssertTrue(childGroup.label.contains("exécuté 2 commandes"), "résumé : \(childGroup.label)")
        XCTAssertEqual(bashCards.count, 0, "cartes Bash cachées sous le groupe replié")
        keep(app, "13i-enfant-replie")
        childGroup.tap()
        expectValue(childGroup, "déplié")
        XCTAssertTrue(bashCards.firstMatch.waitForExistence(timeout: 5), "cartes Bash visibles une fois déplié")
        // `descendants(.any)` compte aussi les éléments imbriqués d'une carte : on vérifie les deux commandes par leur texte.
        for command in ["head -500", "maxdepth"] {
            XCTAssertTrue(bashCards.matching(NSPredicate(format: "label CONTAINS %@", command)).firstMatch.exists,
                          "carte de la commande « \(command) » visible")
        }
        keep(app, "13i-enfant-deplie")
        childGroup.tap()
        expectValue(childGroup, "replié")
        XCTAssertTrue(bashCards.firstMatch.waitForNonExistence(timeout: 5), "cartes de nouveau cachées")

        // Recherche d'un mot présent seulement dans la 2e commande (carte cachée) : le groupe se déplie.
        app.buttons["chat-menu"].tap()
        app.buttons["chat-search"].tap()
        let search = app.textFields["chat-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        if !search.hasFocus { search.tap() }
        search.typeText("maxdepth")
        let counter = app.staticTexts["chat-search-counter"]
        let one = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "1/1"), object: counter)
        XCTAssertEqual(XCTWaiter.wait(for: [one], timeout: 5), .completed, "une correspondance : \(counter.label)")
        expectValue(childGroup, "déplié")
        let found = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Bash, ", "maxdepth")).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 5), "carte de la correspondance visible")
        keep(app, "13i-recherche")
        app.buttons["chat-search-close"].tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()            // retour au parent
        XCTAssertTrue(app.buttons["subagent-open"].firstMatch.waitForExistence(timeout: 10))
    }

    /// Attend la valeur VoiceOver d'un élément (« replié » / « déplié » d'un groupe d'outils, changement animé).
    private func expectValue(_ element: XCUIElement, _ value: String, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "valeur attendue « \(value) » : \(String(describing: element.value))", file: file, line: line)
    }

    /// Parcours réel (lot 13E-2) : projet `~/claude` → Workflows → `ios-ui` (fichier de support
    /// `~/claude/.zcode/workflows/ios-ui.dwf.ts` laissé sur le Mac, sans agent ni argument requis) → « Lancer » →
    /// carte de run « Terminé » sans « Arrêter » → session archivée. Coûte **un prompt GLM** par lancement : la fin
    /// du run relance toujours un tour du modèle (`backgroundResult`), attendu avant l'archivage.
    func testParcoursWorkflowEnregistre() throws {
        let app = try launchSeeded()
        _ = try openWorkspace(app)
        let entry = app.descendants(matching: .any)["workspace-workflows"]
        XCTAssertTrue(entry.waitForExistence(timeout: 20), "entrée Workflows absente (barrière fermée ?)")
        entry.tap()
        let row = app.buttons["workflow-row-ios-ui"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "workflow de support ios-ui listé")
        keep(app, "13e2-liste")
        row.tap()
        let launch = app.buttons["workflow-launch"]
        XCTAssertTrue(launch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["workflow-arg-who"].exists, "champ de l'argument who")
        keep(app, "13e2-lancement")
        launch.tap()

        // Conteneur `.contain` avec libellé « Workflow <nom>, <statut>, <résumé> » : type d'élément non garanti.
        let card = app.descendants(matching: .any)["workflow-run-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 60), "carte de run absente")
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Terminé'"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 90), .completed, "run terminé : \(card.label)")
        XCTAssertTrue(card.label.hasPrefix("Workflow ios-ui"), "libellé de la carte : \(card.label)")
        XCTAssertFalse(app.buttons["workflow-run-stop"].exists, "plus d'« Arrêter » une fois le run terminé")
        keep(app, "13e2-carte")

        // Tour du modèle relancé par la fin du run : réponse affichée, puis plus de « Stop » au composeur.
        let answer = app.descendants(matching: .any).matching(identifier: "assistant-text").firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 120), "réponse du tour relancé par la fin du run")
        let stop = app.descendants(matching: .any)["composer-stop"]
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stop)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 120), .completed, "tour du modèle terminé")
        keep(app, "13e2-fin")

        // Ménage : la session ouverte depuis la liste des workflows est archivée ; retour à cette liste.
        dismissKeyboard(app)
        app.buttons["chat-menu"].tap()
        app.buttons["Archiver la conversation"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["workflows-list"].waitForExistence(timeout: 15),
                      "retour à la liste des workflows après archivage")
    }

    /// Parcours réel (lot 13J, un prompt GLM et un appel de plus après le refus) : icônes de la fiche de l'hôte (bulle
    /// d'état avec la version, feuille web, utilisation), puis une session qui attend une autorisation apparaît en tête
    /// de « Sessions en cours » et s'ouvre depuis la fiche ; la demande est refusée depuis le dock (le dock remplace le
    /// composeur : pas de `composer-stop` pendant l'attente ; le refus dit au modèle de s'arrêter, il répond une fois),
    /// puis la session est archivée. Ménage sur le Mac : journaux de la session (voir CLAUDE.md, « Commandes »).
    func testParcoursSessionsEnCours() throws {
        let app = try launchSeeded()
        app.staticTexts["Mac (test)"].tap()
        waitConnected(app)
        XCTAssertTrue(app.descendants(matching: .any)["host-active-sessions"].waitForExistence(timeout: 15),
                      "section « Sessions en cours »")

        // Bulle d'état : version de l'hôte, puis fermée d'un toucher hors d'elle.
        app.buttons["connection-status"].tap()
        let detail = app.descendants(matching: .any)["connection-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "bulle d'état")
        XCTAssertTrue(detail.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label BEGINSWITH 'ZCode '")).firstMatch.exists, "version affichée")
        keep(app, "13j-1-bulle")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5), "bulle fermée")

        // Feuille web : bouton « Fermer » de `WebFallbackView`.
        app.buttons["host-web"].tap()
        let close = app.buttons["Fermer"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "feuille web ouverte")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "feuille web fermée")
        XCTAssertTrue(app.buttons["host-usage"].waitForExistence(timeout: 5), "icône d'utilisation")

        // Sessions en cours **avant** la nôtre (l'utilisateur peut en avoir) : jamais touchées par le parcours.
        let activeRows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'active-session-'"))
        // Relevé sur un état établi : « Aucune session en cours », ou le même nombre de lignes deux fois à 1 s d'écart.
        var settled = false
        var previousCount = -1
        let settleDeadline = Date().addingTimeInterval(30)
        while Date() < settleDeadline {
            if app.staticTexts["Aucune session en cours"].exists { settled = true; break }
            let count = app.staticTexts["Recherche des sessions…"].exists ? -1 : activeRows.count
            if count > 0, count == previousCount { settled = true; break }
            previousCount = count
            sleep(1)
        }
        XCTAssertTrue(settled, "section chargée")
        let existing = Set(activeRows.allElementsBoundByIndex.map { $0.identifier })
        print("13J sessions en cours déjà là : \(existing.count)")

        // Projet ~/claude depuis la fiche (déjà connectée) : la section du haut peut repousser la ligne hors écran.
        let workspace = app.descendants(matching: .any)["workspace-\(Self.workspace)"]
        for _ in 0..<4 where !workspace.isHittable { app.swipeUp() }
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        XCTAssertTrue(app.collectionViews["sessions-list"].waitForExistence(timeout: 10))
        app.buttons["Nouvelle session"].tap()
        let field = app.descendants(matching: .any)["composer-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Crée le fichier .zcode-check/ui-en-cours.txt contenant OK avec ton outil d'écriture.")
        app.buttons["composer-send"].tap()
        let dock = app.descendants(matching: .any)["interaction-dock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 120), "demande d'autorisation")
        for _ in 0..<2 {                                                     // conversation → projet → fiche
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["host-active-sessions"].waitForExistence(timeout: 10),
                      "retour à la fiche")

        // Seule une ligne absente avant la création peut être la nôtre (d'autres sessions de l'utilisateur peuvent tourner).
        let row = activeRows.matching(NSPredicate(format: "NOT (identifier IN %@)", Array(existing))).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "nouvelle session en attente listée")
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'réponse attendue'"),
                                                object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [waiting], timeout: 20), .completed, "attente annoncée : \(row.label)")
        print("13J session : \(row.identifier)")
        keep(app, "13j-2-sessions-en-cours")
        row.tap()
        XCTAssertTrue(dock.waitForExistence(timeout: 20), "conversation ouverte depuis la fiche")
        // Garde-fou avant tout refus ou archivage : la conversation ouverte est bien celle du parcours (message envoyé ou
        // demande qui nomme le fichier) ; sinon échec sans rien toucher.
        let ours = app.descendants(matching: .any)["chat-list"].descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'ui-en-cours.txt'")).firstMatch
        XCTAssertTrue(ours.waitForExistence(timeout: 20), "conversation du parcours (ui-en-cours.txt)")
        XCTAssertFalse(app.buttons["composer-stop"].exists, "le dock remplace le composeur")

        // Refus depuis le dock (une demande de plus si le modèle insiste, au plus trois), jusqu'à la fin du tour : trois
        // relevés consécutifs sans dock ni `composer-stop`, avec `composer-send`, pour ne pas archiver pendant la réponse.
        let deny = app.buttons["interaction-option-deny"]
        let send = app.buttons["composer-send"]
        let stop = app.buttons["composer-stop"]
        var denied = 0
        var idleChecks = 0
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if deny.isHittable, denied < 3 {
                deny.tap()
                denied += 1
                idleChecks = 0
            } else if denied > 0, !dock.exists, !stop.exists, send.exists {
                idleChecks += 1
                if idleChecks >= 3 { break }
            } else {
                idleChecks = 0
            }
            sleep(1)
        }
        XCTAssertGreaterThan(denied, 0, "demande refusée depuis le dock")
        XCTAssertFalse(dock.exists, "demande retirée")
        XCTAssertGreaterThanOrEqual(idleChecks, 3, "tour terminé avant l'archivage")
        keep(app, "13j-3-apres-refus")
        dismissKeyboard(app)
        app.buttons["chat-menu"].tap()
        app.buttons["Archiver la conversation"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["host-active-sessions"].waitForExistence(timeout: 15),
                      "retour à la fiche après archivage")
    }

    /// Parcours réel sans prompt (lot 13H) : « Ajouter un projet » ouvre l'explorateur de dossiers de l'hôte
    /// (part du home, dossiers seuls) → descente dans le projet de test puis son sous-dossier → « Remonter » →
    /// redescente → « Choisir ce dossier » ajoute le projet → la ligne apparaît → « Retirer » le nettoie.
    /// Exige `TEST_RUNNER_ZCODE_SEED_URL` et `TEST_RUNNER_ZCODE_SEED_TOKEN` (sinon ignoré).
    func testParcoursAjouterProjet() throws {
        let app = try launchSeeded()
        app.staticTexts["Mac (test)"].tap()
        waitConnected(app)

        app.buttons["Ajouter un projet"].tap()
        let picker = app.descendants(matching: .any)["project-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "feuille explorateur ouverte")
        let path = app.descendants(matching: .any)["project-path"]
        XCTAssertTrue(path.waitForExistence(timeout: 10))
        let home = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", Self.home), object: path)
        XCTAssertEqual(XCTWaiter.wait(for: [home], timeout: 15), .completed, "l'explorateur part du home de l'hôte")
        let up = app.buttons["project-up"]
        XCTAssertTrue(up.waitForExistence(timeout: 5))
        XCTAssertFalse(up.isEnabled, "« Remonter » inactif au home")
        keep(app, "13h-explorateur")

        let claude = app.buttons["project-entry-\(Self.workspaceName)"]
        XCTAssertTrue(claude.waitForExistence(timeout: 10), "dossier `claude` proposé (fichiers filtrés)")
        claude.tap()
        let zcode = app.buttons["project-entry-\(Self.subfolder)"]
        XCTAssertTrue(zcode.waitForExistence(timeout: 10), "descente dans `claude`")
        zcode.tap()
        let target = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "\(Self.workspace)/\(Self.subfolder)"), object: path)
        XCTAssertEqual(XCTWaiter.wait(for: [target], timeout: 10), .completed, "chemin courant = le projet")
        XCTAssertTrue(up.isEnabled, "« Remonter » actif sous le home")
        keep(app, "13h-dossier")

        up.tap()
        let backClaude = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", Self.workspace), object: path)
        XCTAssertEqual(XCTWaiter.wait(for: [backClaude], timeout: 10), .completed,
                       "remontée d'un niveau dans la pile (zcode_ios → claude)")
        up.tap()
        let backHome = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", Self.home), object: path)
        XCTAssertEqual(XCTWaiter.wait(for: [backHome], timeout: 10), .completed, "remontée au home")
        XCTAssertFalse(up.isEnabled, "« Remonter » de nouveau inactif au home")
        XCTAssertTrue(app.buttons["project-entry-\(Self.workspaceName)"].waitForExistence(timeout: 10), "retour à la liste du home")
        app.buttons["project-entry-\(Self.workspaceName)"].tap()
        let zcodeAgain = app.buttons["project-entry-\(Self.subfolder)"]
        XCTAssertTrue(zcodeAgain.waitForExistence(timeout: 10), "redescente dans `claude`")
        zcodeAgain.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "\(Self.workspace)/\(Self.subfolder)"), object: path)], timeout: 10),
            .completed, "redescente jusqu'au dossier à ajouter")

        app.buttons["project-choose"].tap()
        let added = app.descendants(matching: .any)["workspace-\(Self.workspace)/\(Self.subfolder)"]
        XCTAssertTrue(added.waitForExistence(timeout: 10), "projet ajouté à la section Projets")
        XCTAssertFalse(picker.exists, "feuille refermée après le choix")
        keep(app, "13h-ajoute")

        added.swipeLeft()
        app.buttons["Retirer"].tap()
        XCTAssertTrue(added.waitForNonExistence(timeout: 10), "projet retiré (nettoyage)")
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Referme le clavier logiciel : resté ouvert après l'envoi, iOS 26/27 replie les boutons de la barre
    /// (jauge, menu « ⋯ ») dans le bouton de débordement et les rend introuvables au test. Le geste vise la
    /// conversation (`scrollDismissesKeyboard(.interactively)`) et la fait glisser jusque dans le clavier : un simple
    /// `swipeDown` ne l'atteint pas, et `scrollViews.firstMatch` peut être la rangée de puces du composeur.
    private func dismissKeyboard(_ app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let start = app.scrollViews["chat-list"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "clavier refermé")
    }
}
