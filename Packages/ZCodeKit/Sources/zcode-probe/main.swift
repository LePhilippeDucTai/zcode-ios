import Foundation
import ZCodeClient
import ZCodeWire

let usage = """
Usage :
  zcode-probe info [--url URL] [--token-file FICHIER]
  zcode-probe run SCRIPT.json [--url URL] [--token-file FICHIER] [--record DOSSIER]
  zcode-probe check [--url URL] [--token-file FICHIER] [--workspace CHEMIN]
  zcode-probe goal [--url URL] [--token-file FICHIER] [--workspace CHEMIN] [--record DOSSIER]
  zcode-probe attach [--url URL] [--token-file FICHIER] [--workspace CHEMIN] [--record DOSSIER]
  zcode-probe extensions --workspace CHEMIN --marketplace CHEMIN [--invoke] [--record DOSSIER] [--url URL] [--token-file FICHIER]
  zcode-probe composer --workspace CHEMIN [--fork | --workflow] [--record DOSSIER] [--url URL] [--token-file FICHIER]
  zcode-probe workflows --workspace CHEMIN [--with-agent [--cancel]] [--mode MODE] [--record DOSSIER] [--url URL] [--token-file FICHIER]

Par défaut : --url http://127.0.0.1:3030, --token-file ~/.config/zcode-web/token, --workspace $ZCODE_PROBE_WORKSPACE (sinon le home).
La variable ZCODE_TOKEN, si définie, remplace le fichier de token.
Dans un script, ${NOM} est remplacé par la variable d'environnement NOM.
check : test de contrat de bout en bout (crée puis supprime une session ; code de sortie 0 si tout passe).
goal : vraie boucle d'un Goal trivial (≈ 2 à 4 appels au modèle) ; états enregistrés avec --record ; code 0 si atteint.
attach : pièce jointe réelle (image de test) téléversée, envoyée, relue, décrite par le modèle (≤ 2 appels) ; code 0 si tout passe.
extensions : contrat réel des sous-agents et des plugins sur des noms jetables (aucun prompt), puis nettoyage ; --workspace
  sous un dossier .zcode-check (obligatoire), --marketplace = dossier de Probe/make-plugin-marketplace.sh côté hôte ;
  --invoke invoque aussi le sous-agent jetable (≈ 6 appels au modèle observés) ; code 0 si tout passe.
composer : contrat réel du composeur (lot 13C) dans un projet sous .zcode-check ; sans option, aucun prompt ;
  --fork : un prompt (PONG) puis forkAssistant ; --workflow : un prompt /workflow et un petit run, annulé ; code 0 si tout passe.
workflows : workflows enregistrés (lot 13E-2) dans un projet sous .zcode-check, sur la machine de l'hôte (les fichiers
  .dwf.ts y sont écrits puis supprimés) ; sans --with-agent : un appel GLM (la fin d'un run relance toujours le modèle) ;
  --with-agent : quelques prompts, un agent demande à écrire un fichier (demande refusée, run arrêté) ;
  --cancel (avec --with-agent) : run arrêté (cancelBackgroundWork) pendant que la demande attend, au lieu du refus ;
  --mode MODE : mode envoyé à la création des sessions (rien par défaut) ; code 0 si tout passe.
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let environment = ProcessInfo.processInfo.environment
do {
    let options = try ProbeOptions.parse(Array(CommandLine.arguments.dropFirst()), environment: environment)
    let endpoint = HostEndpoint(baseURL: options.url, token: try options.loadToken())
    switch options.command {
    case .info:
        let info = try await ServerInfo.fetch(from: endpoint)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(info), as: UTF8.self))
    case .run(let scriptURL):
        let script = try ProbeScript.load(from: scriptURL, environment: environment)
        let output = try ProbeOutput(recordDirectory: options.recordDirectory)
        let client = try await ZCodeConnector.connect(to: endpoint)
        try await ProbeRunner(client: client, output: output).run(script)
        await client.close()
    case .check:
        let report = await ContractCheck(endpoint: endpoint, workspace: options.workspace).run()
        print(report.succeeded ? "Contrat respecté." : "Contrat NON respecté.")
        exit(report.succeeded ? 0 : 1)
    case .goal:
        let output = try ProbeOutput(recordDirectory: options.recordDirectory)
        let report = await GoalRun(endpoint: endpoint, workspace: options.workspace, output: output).run()
        print(report.succeeded ? "Goal atteint." : "Goal NON atteint.")
        exit(report.succeeded ? 0 : 1)
    case .attach:
        let output = try ProbeOutput(recordDirectory: options.recordDirectory)
        let report = await AttachRun(endpoint: endpoint, workspace: options.workspace, output: output).run()
        print(report.succeeded ? "Pièces jointes conformes." : "Pièces jointes NON conformes.")
        exit(report.succeeded ? 0 : 1)
    case .extensions:
        let output = try ProbeOutput(recordDirectory: options.recordDirectory)
        let report = await ExtensionsRun(endpoint: endpoint, workspace: options.workspace, marketplace: options.marketplace ?? "",
                                         invoke: options.invoke, output: output).run()
        print(report.succeeded ? "Extensions conformes." : "Extensions NON conformes.")
        exit(report.succeeded ? 0 : 1)
    case .composer:
        let output = try ProbeOutput(recordDirectory: options.recordDirectory)
        let report = await ComposerRun(endpoint: endpoint, workspace: options.workspace,
                                       scenario: options.composerScenario, output: output).run()
        print(report.succeeded ? "Composeur conforme." : "Composeur NON conforme.")
        exit(report.succeeded ? 0 : 1)
    case .workflows:
        let output = try ProbeOutput(recordDirectory: options.recordDirectory)
        let report = await WorkflowsRun(endpoint: endpoint, workspace: options.workspace, withAgent: options.workflowsWithAgent,
                                        cancelWhilePending: options.workflowsCancelWhilePending, sessionMode: options.sessionMode, output: output).run()
        print(report.succeeded ? "Workflows conformes." : "Workflows NON conformes.")
        exit(report.succeeded ? 0 : 1)
    }
} catch let error as ProbeOptions.ParseError {
    fail("Erreur : \(error)\n\n\(usage)", code: 2)
} catch {
    fail("Erreur : \(error)", code: 1)
}
