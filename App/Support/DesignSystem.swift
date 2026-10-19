import SwiftUI
import UIKit
import ZCodeAppCore

/// Native iOS typography: SF Pro for UI, SF Mono for technical output.
/// Semantic styles scale with Dynamic Type; no external fonts are bundled.
enum ZCodeTypography {
    static let body: Font = .system(.body, design: .default)
    /// Texte d'une réflexion : une taille sous le corps des réponses (comme l'app Claude mobile).
    static let reasoning: Font = .system(.callout, design: .default)
    static let reasoningHeading: Font = .system(.callout, design: .default, weight: .semibold)
    static let heading: Font = .system(.title3, design: .default, weight: .semibold)
    static let subheading: Font = .system(.headline, design: .default, weight: .semibold)
    static let smallHeading: Font = .system(.subheadline, design: .default, weight: .semibold)
    static let navigationTitle: Font = .system(.subheadline, design: .default, weight: .semibold)
    static let control: Font = .system(.subheadline, design: .default, weight: .medium)
    static let metadata: Font = .system(.caption, design: .default)
    static let code: Font = .system(.callout, design: .monospaced)
    static let monoCaption: Font = .system(.caption, design: .monospaced)

    // Cartes d'outils (Bash, Edit, Read…) : compactes, comme l'app Claude mobile.
    /// Code d'une carte : commande, entrée, sortie (style `.compact` de `CodeBlock`), environ 12 pt.
    static let toolCode: Font = monoCaption
    /// Lignes de diff d'une carte et compteurs `+a −d` de son en-tête, environ 11 pt.
    static let toolDiff: Font = .system(.caption2, design: .monospaced)
    /// En-tête d'une carte : icône d'état, nom de l'outil, statut s'il n'a pas réussi.
    static let toolIcon: Font = .system(.footnote, design: .default)
    static let toolName: Font = .system(.footnote, design: .default, weight: .bold)
    static let toolStatus: Font = .system(.caption2, design: .default)
    /// Commande ou chemin résumé dans l'en-tête d'une carte.
    static let toolSummary: Font = monoCaption
}

/// Couleurs de la coloration syntaxique, proches des thèmes par défaut de Xcode ; claires et sombres.
enum ZCodeSyntaxColors {
    private static let keyword = dynamic(light: 0x9B2393, dark: 0xFC5FA3)
    private static let string = dynamic(light: 0xC41A16, dark: 0xFC6A5D)
    private static let comment = dynamic(light: 0x5D6C79, dark: 0x7F8C98)
    private static let number = dynamic(light: 0x1C00CF, dark: 0xD0BF69)
    private static let type = dynamic(light: 0x0B4F79, dark: 0x5DD8FF)

    /// `nil` : couleur du texte ordinaire.
    static func color(for kind: SyntaxTokenKind) -> Color? {
        switch kind {
        case .keyword: keyword
        case .string: string
        case .comment: comment
        case .number: number
        case .type: type
        case .plain: nil
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) })
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
