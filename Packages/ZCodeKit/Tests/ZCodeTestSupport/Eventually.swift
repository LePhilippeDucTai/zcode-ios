import Foundation

public struct EventuallyTimeout: Error, CustomStringConvertible {
    public var description: String { "condition non atteinte dans le délai" }
}

/// Attend qu'une sonde renvoie une valeur (sondage toutes les 10 ms).
public func eventually<T>(
    timeout: Duration = .seconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ probe: () async throws -> T?
) async throws -> T {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if let value = try await probe() { return value }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw EventuallyTimeout()
}
