import SwiftUI
import UIKit
import ZCodeAppCore
import ZCodeV4

@main
struct ZCodeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel

    init() {
        let hostStore = HostStore(persistence: UserDefaultsHostPersistence(), tokens: KeychainTokenStore())
        #if DEBUG
        // Tests UI : hôte injecté par l'environnement de lancement (jamais dans un build Release).
        hostStore.applyDebugSeed(environment: ProcessInfo.processInfo.environment)
        #endif
        let clientId = ClientIdentity.clientId(storage: UserDefaultsClientIDStorage())
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "ZCode iOS \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        _model = State(initialValue: AppModel(hostStore: hostStore, dependencies: .live(clientId: clientId, appVersion: version),
                                              archiveStore: ArchiveStore(persistence: UserDefaultsArchivePersistence()),
                                              seenStore: SeenStore(persistence: UserDefaultsLocalPersistence(key: SeenStore.storageKey)),
                                              pinStore: PinStore(persistence: UserDefaultsLocalPersistence(key: PinStore.storageKey)),
                                              promptStore: PromptStore(persistence: UserDefaultsLocalPersistence(key: PromptStore.storageKey)),
                                              offlineCache: ConversationCache(storage: FileOfflineCacheStorage.applicationSupport())))
    }

    var body: some Scene {
        WindowGroup {
            HostsView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.sceneDidBecomeActive() }
            } else if phase == .background {
                model.sceneDidEnterBackground()                                   // iOS peut tuer l'app sans onDisappear
                OfflineSaveTask.run(model: model)
            }
        }
    }
}

/// Écriture des copies hors ligne au passage en arrière-plan, sous une tâche d'arrière-plan iOS.
/// `finish` est idempotent : l'expiration et la fin normale ne terminent jamais la tâche deux fois.
@MainActor
private final class OfflineSaveTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private var work: Task<Void, Never>?

    static func run(model: AppModel) {
        let job = OfflineSaveTask()
        job.identifier = UIApplication.shared.beginBackgroundTask(withName: "Copie hors ligne") {
            // Appelé sur le fil principal : annuler l'écriture, puis rendre la tâche à iOS.
            MainActor.assumeIsolated {
                job.work?.cancel()
                job.finish()
            }
        }
        job.work = Task {
            await model.saveOfflineCopies()
            job.finish()
        }
    }

    private func finish() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
