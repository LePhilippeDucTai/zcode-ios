import Foundation
import Testing
import ZCodeAppCore
import ZCodeV4

struct ActiveSessionsTests {
    func live(_ workspace: String, _ sessions: [SessionSummary]) -> ActiveSessionsSource {
        ActiveSessionsSource(workspace: workspace, status: .live, sessions: sessions)
    }

    @Test func filtreAttenteEtEnCours() throws {
        let running = try makeSummary("sess_run", phase: "running")
        let prewarming = try makeSummary("sess_pre", phase: "prewarming")
        let waiting = try makeSummary("sess_wait", phase: "completedSuccess", pendingPermissions: 1)
        let done = try makeSummary("sess_done", phase: "completedSuccess")
        let failed = try makeSummary("sess_err", phase: "error")
        let state = ActiveSessions.state(from: [live("/p/a", [running, prewarming, waiting, done, failed])])
        guard case .entries(let shown, let hidden) = state else { Issue.record("entrées attendues"); return }
        #expect(Set(shown.map(\.id)) == ["sess_run", "sess_pre", "sess_wait"])
        #expect(hidden == 0)
    }

    @Test func attenteDAbordPuisActiviteRecente() throws {
        let oldRun = try makeSummary("r1", lastActivityAt: 100, phase: "running")
        let newRun = try makeSummary("r2", lastActivityAt: 300, phase: "running")
        let oldWait = try makeSummary("w1", lastActivityAt: 50, pendingPermissions: 2)
        let newWait = try makeSummary("w2", lastActivityAt: 200, phase: "running", pendingPermissions: 1)
        let state = ActiveSessions.state(from: [live("/p/a", [oldRun, oldWait]), live("/p/b", [newRun, newWait])])
        guard case .entries(let shown, _) = state else { Issue.record("entrées attendues"); return }
        #expect(shown.map(\.id) == ["w2", "w1", "r2", "r1"])
        #expect(shown.map(\.workspace) == ["/p/b", "/p/a", "/p/b", "/p/a"])
        #expect(shown[0].projectName == "b")
        #expect(shown[0].waiting && !shown[2].waiting)
    }

    @Test func plafondEtLibelleDesAutres() throws {
        let sessions = try (0..<7).map { try makeSummary("s\($0)", lastActivityAt: Double($0), phase: "running") }
        guard case .entries(let shown, let hidden) = ActiveSessions.state(from: [live("/p/a", sessions)]) else {
            Issue.record("entrées attendues"); return
        }
        #expect(shown.map(\.id) == ["s6", "s5", "s4", "s3", "s2"])
        #expect(hidden == 2)
        #expect(ActiveSessions.hiddenLabel(1) == "et 1 autre session en cours")
        #expect(ActiveSessions.hiddenLabel(2) == "et 2 autres sessions en cours")
    }

    @Test func copieHorsLigneEtListeIndisponibleIgnorees() throws {
        let run = try makeSummary("sess_run", phase: "running")
        let offline = ActiveSessionsSource(workspace: "/p/a", status: .unavailable, sessions: [run])
        #expect(ActiveSessions.state(from: [offline]) == .empty)
    }

    @Test func chargementTantQueRienEtUneListeAttend() throws {
        let loading = ActiveSessionsSource(workspace: "/p/a", status: .loading, sessions: [])
        let failed = ActiveSessionsSource(workspace: "/p/b", status: .unavailable, sessions: [])
        #expect(ActiveSessions.state(from: [loading, failed]) == .loading)
        #expect(ActiveSessions.state(from: [failed]) == .empty)                 // une liste en échec ne bloque rien
        #expect(ActiveSessions.state(from: []) == .empty)                       // aucun projet
        let run = try makeSummary("sess_run", phase: "running")
        guard case .entries = ActiveSessions.state(from: [loading, live("/p/c", [run])]) else {
            Issue.record("les entrées d'une liste prête passent avant le chargement des autres"); return
        }
    }

    @Test func memeSessionUneSeuleFois() throws {
        let run = try makeSummary("sess_run", phase: "running")
        guard case .entries(let shown, _) = ActiveSessions.state(from: [live("/p/a", [run]), live("/p/a", [run])]) else {
            Issue.record("entrées attendues"); return
        }
        #expect(shown.count == 1)
    }

    @Test func activitéÉgaleDépartagéeParIdentifiant() throws {
        let later = try makeSummary("sess_b", lastActivityAt: 100, phase: "running")
        let earlier = try makeSummary("sess_a", lastActivityAt: 100, phase: "running")
        let waitB = try makeSummary("wait_b", lastActivityAt: 100, pendingPermissions: 1)
        let waitA = try makeSummary("wait_a", lastActivityAt: 100, pendingPermissions: 1)
        guard case .entries(let shown, _) = ActiveSessions.state(from: [live("/p/a", [later, waitB, earlier, waitA])]) else {
            Issue.record("entrées attendues"); return
        }
        #expect(shown.map(\.id) == ["wait_a", "wait_b", "sess_a", "sess_b"])
    }
}
