import Foundation
import ZCodeV4
import ZCodeWire

/// Formulaire des arguments d'un workflow enregistré, à partir de ses déclarations (`WorkflowArgSpec`). Pur : aucune
/// E/S, le même formulaire sert à l'affichage et à l'envoi. Un type inconnu est traité comme `json` (le serveur valide).
/// Le nombre accepte la virgule décimale, comme `PluginConfigForm`. Seules les clés déclarées partent dans la commande.
public struct WorkflowArgsForm: Equatable, Sendable {
    public struct Field: Equatable, Sendable, Identifiable {
        public let spec: WorkflowArgSpec
        /// Saisie pour `string`, `number` et `json` ; préremplie depuis le défaut quand son type correspond.
        public var text: String
        /// Saisie pour `boolean` : `nil` tant que ni défaut ni toucher.
        public var flag: Bool?

        public var id: String { spec.name }
    }

    public var fields: [Field]

    public init(specs: [WorkflowArgSpec]) {
        fields = specs.map { spec in
            var field = Field(spec: spec, text: "", flag: nil)
            guard let value = spec.defaultValue else { return field }
            if spec.type == .boolean {
                field.flag = value.boolValue
            } else if spec.type == .string {
                field.text = value.stringValue ?? ""
            } else if spec.type == .number {
                field.text = value.numberValue.map(Self.text) ?? ""
            } else {
                field.text = (try? value.jsonData()).map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
            return field
        }
    }

    /// Erreur par champ (nom → message), vide si tout est valide.
    public var errors: [String: String] {
        var errors: [String: String] = [:]
        for field in fields {
            if case .failure(let message) = Self.outcome(field) {
                errors[field.id] = message
            }
        }
        return errors
    }

    /// Arguments à envoyer ; `nil` si un champ est invalide. Un champ vide non requis est omis.
    public func payload() -> [String: JSONValue]? {
        var payload: [String: JSONValue] = [:]
        for field in fields {
            switch Self.outcome(field) {
            case .omitted: continue
            case .value(let value): payload[field.id] = value
            case .failure: return nil
            }
        }
        return payload
    }

    // MARK: - Règles

    private enum Outcome: Equatable {
        case omitted
        case value(JSONValue)
        case failure(String)
    }

    private static func outcome(_ field: Field) -> Outcome {
        let spec = field.spec
        if spec.type == .boolean {
            guard let on = field.flag ?? spec.defaultValue?.boolValue else {
                return spec.required ? .failure("Obligatoire") : .omitted
            }
            return .value(.bool(on))
        }
        // Une chaîne garde ses espaces ; nombre et JSON ignorent les espaces autour, « vide » veut dire blanc seul.
        let trimmed = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEmpty = spec.type == .string ? field.text.isEmpty : trimmed.isEmpty
        if isEmpty {
            return spec.required ? .failure("Obligatoire") : .omitted
        }
        if spec.type == .string {
            return .value(.string(field.text))
        }
        if spec.type == .number {
            guard let number = number(trimmed) else { return .failure("Nombre attendu") }
            return .value(.number(number))
        }
        guard let value = try? JSONValue.decode(Data(trimmed.utf8)) else { return .failure("JSON invalide") }
        return .value(value)
    }

    /// Nombre fini ; la virgule décimale est acceptée. `Double` accepte « nan » et « inf » : ils sont refusés ici.
    private static func number(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite else { return nil }
        return value
    }

    /// Format de préremplissage : un entier sans « .0 ».
    private static func text(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
        return String(number)
    }
}
