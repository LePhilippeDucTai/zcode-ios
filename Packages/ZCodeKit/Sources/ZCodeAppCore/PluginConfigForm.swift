import Foundation
import ZCodeV4
import ZCodeWire

/// Correctif de configuration envoyé à l'hôte (`configurePlugin`) : les seules options modifiées et les clés à effacer.
public struct PluginConfigPatch: Equatable, Sendable {
    public var options: [String: JSONValue]
    public var clearKeys: [String]

    public init(options: [String: JSONValue], clearKeys: [String]) {
        self.options = options
        self.clearKeys = clearKeys
    }

    /// Rien à envoyer.
    public var isEmpty: Bool { options.isEmpty && clearKeys.isEmpty }
}

/// Formulaire de configuration d'un plugin installé, dans la portée de l'écran. Mêmes règles que ZCode Web
/// (`pluginConfigPatch.ts`) : seuls les champs modifiés partent (la valeur effective, qui peut venir de l'utilisateur ou
/// d'un défaut, n'est jamais réécrite dans le projet), « Effacer » va dans `clearKeys`, une chaîne vide sur une option
/// sensible veut dire « inchangé ». Une option sensible n'est jamais préremplie : l'hôte ne la renvoie pas, et le
/// formulaire n'en garde que ce que l'utilisateur saisit, le temps de la feuille.
public struct PluginConfigForm: Equatable, Sendable {
    /// Ce que l'utilisateur a fait d'un champ ; `nil` sur le champ = pas touché.
    public enum Draft: Equatable, Sendable {
        case value(String)
        case toggle(Bool)
        case clear
    }

    public struct Field: Equatable, Sendable, Identifiable {
        public let option: PluginConfigOption
        /// Valeur effective (enregistrée, sinon le défaut) en texte ; vide pour une option sensible.
        public let currentText: String
        /// L'hôte a une valeur pour cette option (`optionSources`), y compris une option sensible.
        public let isSet: Bool
        /// Portée qui définit la valeur (`user` ou `workspace`).
        public let source: String?
        /// « Effacer » a un effet dans la portée du formulaire (règle de `PluginConfigControls.tsx`, ZCode Web) : la valeur
        /// y est définie, et l'option est sensible ou la portée est un projet. Sinon `clearOptionKeys` ne ferait rien sur
        /// l'hôte (valeur d'une autre portée, ou valeur ordinaire de l'utilisateur, qu'on remplace sans l'effacer).
        public let canClear: Bool
        /// Un effacement impossible (`canClear == false`) est refusé : le brouillon garde sa valeur précédente.
        public var draft: Draft? {
            didSet { if draft == .clear, !canClear { draft = oldValue } }
        }

        public var id: String { option.key }

        /// Titre affiché : le titre de l'option, sinon sa clé (jamais une chaîne vide).
        public var title: String {
            guard let title = option.title, !title.isEmpty else { return option.key }
            return title
        }

        /// Description de l'option, absente si vide.
        public var hint: String? {
            guard let description = option.description, !description.isEmpty else { return nil }
            return description
        }

        /// Texte du champ : la saisie, sinon la valeur actuelle.
        public var text: String {
            if case .value(let text)? = draft { return text }
            return currentText
        }

        /// Position de l'interrupteur d'une option booléenne : la saisie, sinon la valeur actuelle.
        public var isOn: Bool {
            if case .toggle(let on)? = draft { return on }
            return currentText == "true"
        }

        /// Le champ sera effacé à l'enregistrement.
        public var isCleared: Bool { draft == .clear }
    }

    public var fields: [Field]
    /// Portée où le formulaire sera enregistré (celle de l'écran).
    public let scope: ExtensionScope

    public init(scope: ExtensionScope, plugin: PluginInfo) {
        self.scope = scope
        fields = plugin.userConfig.map { option in
            let source = plugin.optionSources[option.key]
            let canClear = source == scope.wireName && (option.sensitive || scope.workspacePath != nil)
            return Field(
                option: option,
                currentText: option.sensitive ? "" : Self.text(plugin.configuredOptions[option.key] ?? option.defaultValue),
                isSet: source != nil, source: source, canClear: canClear, draft: nil)
        }
    }

    /// Pose (ou retire, avec `nil`) le brouillon d'un champ ; une clé inconnue est ignorée.
    public mutating func set(_ draft: Draft?, for key: String) {
        guard let index = fields.firstIndex(where: { $0.id == key }) else { return }
        fields[index].draft = draft
    }

    /// Défauts de saisie, par clé ; vide quand le formulaire est valide.
    public func issues() -> [String: String] {
        var issues: [String: String] = [:]
        for field in fields {
            if field.option.required, !Self.hasValue(field) {
                issues[field.id] = "Obligatoire."
            } else if case .failure(let failure) = Self.send(field) {
                issues[field.id] = failure.message
            }
        }
        return issues
    }

    /// Correctif à envoyer. Un champ en défaut de saisie n'y figure pas : `issues()` doit être vide avant d'enregistrer.
    public func patch() -> PluginConfigPatch {
        var patch = PluginConfigPatch(options: [:], clearKeys: [])
        for field in fields {
            if field.draft == .clear {
                patch.clearKeys.append(field.id)
            } else if case .success(let value?) = Self.send(field) {
                patch.options[field.id] = value
            }
        }
        return patch
    }

    // MARK: - Règles

    /// Valeur à envoyer pour un champ : `nil` = rien, échec = défaut de saisie.
    private static func send(_ field: Field) -> Result<JSONValue?, Failure> {
        switch field.draft {
        case nil, .clear?:
            return .success(nil)
        case .toggle(let on)?:
            return .success(.bool(on))
        case .value(let text)?:
            // Une valeur sensible vide veut dire « inchangé » ; seul « Effacer » retire la valeur.
            if field.option.sensitive, text.isEmpty { return .success(nil) }
            switch field.option.type {
            case "number":
                guard let number = number(text) else { return .failure(Failure(message: "Nombre attendu.")) }
                return .success(.number(number))
            case "boolean":
                switch text.lowercased() {
                case "true": return .success(.bool(true))
                case "false": return .success(.bool(false))
                default: return .failure(Failure(message: "Valeur booléenne attendue."))
                }
            default:
                return .success(.string(text))
            }
        }
    }

    private struct Failure: Error {
        let message: String
    }

    /// Nombre fini ; la virgule décimale du clavier français est acceptée. Une chaîne vide n'est pas un zéro.
    private static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, trimmed.allSatisfy({ "0123456789+-.eE".contains($0) }),
              let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// Le champ aura une valeur effective une fois le formulaire enregistré.
    private static func hasValue(_ field: Field) -> Bool {
        switch field.draft {
        case .clear?: return false
        case .toggle?: return true
        case .value(let text)?:
            // Sensible : vide = inchangé, donc la valeur de l'hôte reste.
            return !text.isEmpty || (field.option.sensitive && hasHostValue(field))
        case nil:
            return field.option.sensitive ? hasHostValue(field) : !field.currentText.isEmpty
        }
    }

    /// Valeur connue de l'hôte pour une option sensible, qu'on ne relit pas : définie, ou défaut non vide.
    private static func hasHostValue(_ field: Field) -> Bool {
        if field.isSet { return true }
        guard let fallback = field.option.defaultValue else { return false }
        return text(fallback) != ""
    }

    private static func text(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text)?: return text
        case .bool(let on)?: return on ? "true" : "false"
        case .number(let number)?:
            if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
            return String(number)
        default: return ""
        }
    }
}
