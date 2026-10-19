import Foundation

/// Valeur d'énumération du protocole qui accepte toute chaîne.
///
/// Le protocole ZCode évolue vite : une phase, un statut ou un type inconnu est conservé tel quel
/// (et affiché de façon générique) au lieu de faire échouer le décodage de toute la trame.
/// Les conformants déclarent `rawValue` et un `init(rawValue:)` **non faillible** ; l'encodage et le
/// décodage en chaîne simple viennent de l'implémentation standard de `RawRepresentable`.
public protocol OpenEnum: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible
where RawValue == String {
    init(rawValue: String)
}

extension OpenEnum {
    public var description: String { rawValue }
}
