import Foundation
import Synchronization
import Testing
import ZCodeClient
import ZCodeRPC

final class PingCounter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

struct KeepAliveTests {
    @Test func pingSansReponseSignaleLaPerte() async {
        let start = ContinuousClock.now
        let failure = await KeepAlive.run(every: .milliseconds(10), timeout: .milliseconds(50)) {
            try await Task.sleep(for: .seconds(30))        // socket muet : jamais de pong
        }
        guard case .connectionFailed(let message)? = failure else { Issue.record("perte attendue"); return }
        #expect(message.contains("ping"))
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func pingRefuseSignaleLaPerte() async {
        struct Refus: Error {}
        let failure = await KeepAlive.run(every: .milliseconds(10), timeout: .seconds(1)) { throw Refus() }
        guard case .connectionFailed? = failure else { Issue.record("perte attendue"); return }
    }

    @Test func pingsReussisJusquALAnnulation() async {
        let counter = PingCounter()
        let loop = Task {
            await KeepAlive.run(every: .milliseconds(10), timeout: .seconds(1)) { counter.increment() }
        }
        // Attente d'un état (3 pings) plutôt que d'une durée fixe : sous charge, le planificateur peut retarder la boucle.
        let deadline = ContinuousClock.now + .seconds(10)
        while counter.count < 3, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        loop.cancel()
        #expect(await loop.value == nil)
        #expect(counter.count >= 3)
    }
}
