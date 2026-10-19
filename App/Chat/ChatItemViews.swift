import SwiftUI
import UIKit
import ZCodeAppCore
import ZCodeV4
import ZCodeWire

struct ChatItemView: View {
    let item: ChatItem
    var canFork = false

    var body: some View {
        switch item {
        case .user(let rowId, let input):
            UserBubble(text: input.text, attachments: input.attachments, rowId: rowId)
        case .assistant(let rowId, let text):
            AssistantTextView(text: text).messageMenu(text: item.copyableText, rowId: rowId, forkable: canFork)
        case .reasoning(_, let reasoning): ReasoningView(reasoning: reasoning)
        case .tool(_, let call, let subagent): ToolCallCard(call: call, subagent: subagent)
        case .subagent(_, let subagent): SubagentView(subagent: subagent)
        case .marker(_, let label): MarkerView(label: label)
        case .unsupported(_, let kind, let json): UnsupportedCard(kind: kind, json: json)
        }
    }
}

/// Lecture d'une image jointe, fournie par l'écran de la conversation (les cellules n'ont pas le modèle).
/// Toujours égal à lui-même : le chargeur ne dépend que de la conversation, que l'écran garde. Sans cela, chaque évaluation
/// du corps de `ChatView` (à chaque delta de la réponse) en recréerait un et invaliderait toutes les vignettes.
struct AttachmentLoader: Sendable, Equatable {
    var load: @MainActor @Sendable (AttachmentRef) async -> Data? = { _ in nil }

    static func == (lhs: AttachmentLoader, rhs: AttachmentLoader) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var attachmentLoader = AttachmentLoader()
}

struct UserBubble: View {
    let text: String
    var attachments: [AttachmentRef] = []
    /// Ligne du message ; `nil` pour un guide en attente (pas encore une ligne, pas de menu).
    var rowId: Int?
    @Environment(\.openImageGallery) private var openGallery

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !attachments.isEmpty {
                // Jusqu'à 8 pièces jointes de 88 pt : alignées à droite si elles tiennent, sinon défilement horizontal
                // (la rangée ne doit jamais élargir la bulle au-delà de l'écran).
                ViewThatFits(in: .horizontal) {
                    attachmentRow
                    ScrollView(.horizontal, showsIndicators: false) { attachmentRow }
                        .defaultScrollAnchor(.trailing)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    Spacer(minLength: 40)
                    MathMessageText(text: text)
                        .font(ZCodeTypography.body)
                        .lineSpacing(3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                        .messageMenu(text: text, rowId: rowId)
                }
            }
        }
    }
}

extension UserBubble {
    private var attachmentRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                SentAttachmentView(attachment: attachment)
                    .onTapGesture {
                        if let gallery = ImageGallery.sent(attachments, tapped: index) { openGallery.open(gallery) }
                    }
                    .accessibilityAddTraits(attachment.isImage ? .isButton : [])
                    .accessibilityHint(attachment.isImage ? "Afficher en plein écran" : "")
                    .accessibilityIdentifier("user-attachment-\(index)")
            }
        }
    }
}

/// Pièce jointe d'un message envoyé : vignette d'une image, pastille d'un document.
struct SentAttachmentView: View {
    let attachment: AttachmentRef
    @Environment(\.attachmentLoader) private var loader
    @State private var image: UIImage?

    var body: some View {
        Group {
            if attachment.isImage {
                ZStack {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 88, height: 88)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .task(id: attachment.readableRef) {
                    image = nil
                    guard let data = await loader.load(attachment) else { return }
                    image = await Task.detached(priority: .utility) { ImageDecoding.downsampled(data, maxPixelSize: 264) }.value
                }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(attachment.fileName).font(.caption).lineLimit(1)
                        Text(attachment.bytes.formatted(.byteCount(style: .file))).font(.caption2).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "doc")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: 240, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .accessibilityLabel(attachment.fileName)
    }
}

struct AssistantTextView: View {
    let text: AssistantText

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if text.state == .streaming {
                // Texte brut pendant le streaming : le markdown n'est calculé qu'une fois la ligne terminée.
                Text(text.text)
                    .font(ZCodeTypography.body)
                    .lineSpacing(3)
            } else {
                MarkdownText(markdown: text.text).equatable()
            }
            if text.state == .interrupted || text.state == .failed {
                Text(text.state == .failed ? "Réponse en échec" : "Réponse interrompue")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)                  // le texte est lu par ses enfants (jamais le Markdown brut) ; « Copier » des blocs de code reste atteignable
        .accessibilityIdentifier("assistant-text")
    }
}

struct ReasoningView: View {
    let reasoning: Reasoning
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Group {
                if reasoning.showsMarkdown {
                    MarkdownText(markdown: reasoning.text, style: .reasoning).equatable()
                } else {
                    // Streaming : texte brut, le Markdown n'est calculé qu'une fois la réflexion figée.
                    Text(reasoning.text)
                        .font(ZCodeTypography.reasoning)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(reasoning.label, systemImage: "brain").font(ZCodeTypography.metadata).foregroundStyle(.secondary)
        }
    }
}

struct ToolCallCard: View {
    let call: ToolCall
    let subagent: SubagentLink?
    /// Calculé une fois par carte : un Write qui crée un gros fichier n'a pas de diff de l'hôte, l'app le recalculerait à
    /// chaque rendu (ouverture, défilement de la `LazyVStack`).
    private let diff: FileDiff?
    private let timing: ToolTiming?
    @State private var expanded = false

    init(call: ToolCall, subagent: SubagentLink? = nil) {
        self.call = call
        self.subagent = subagent
        diff = call.fileDiff
        timing = call.timing
    }

    /// Carte Agent associée à un sous-agent : son titre remplace le résumé, son statut remplace celui de l'outil.
    private var summaryText: String? { subagent?.title ?? call.summary }
    private var statusText: String? {
        if let subagent { return subagent.isFinishedSuccess ? nil : subagent.statusLabel }
        return call.status == .success ? nil : call.status.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            card
            if let subagent, let child = subagent.childSessionId {
                SubagentOpenButton(link: subagent, childSessionId: child)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var card: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let text = subagent?.summaryText, !text.isEmpty {
                    Text(text).font(ZCodeTypography.metadata).foregroundStyle(.secondary)
                }
                if let bounds = call.boundsLabel(.current) {
                    Text(bounds).font(ZCodeTypography.metadata).foregroundStyle(.secondary).monospacedDigit()
                }
                if let diff {
                    if let path = diff.path {
                        DiffStatsLabel(path: path, additions: diff.additions, deletions: diff.deletions,
                                       font: ZCodeTypography.toolDiff)
                    }
                    DiffView(file: diff, maxLines: 200, lineFont: ZCodeTypography.toolDiff)
                } else if let command = call.shellCommand {
                    // Outil shell : la commande seule, copiable telle quelle (le JSON de l'entrée ne se colle pas dans
                    // un terminal) ; sa description éventuelle au-dessus.
                    if let description = call.input?["description"]?.stringValue, !description.isEmpty {
                        Text(description).font(ZCodeTypography.metadata).foregroundStyle(.secondary)
                    }
                    ToolTextBlock(language: "bash", text: command, part: .command)
                } else if let input = call.input {
                    ToolTextBlock(language: "json", text: input.prettyText, part: .input)
                } else if !call.inputText.isEmpty {
                    ToolTextBlock(language: nil, text: call.inputText, part: .input)
                }
                if let output = call.output, !output.text.isEmpty {
                    ToolTextBlock(language: nil, text: output.text, part: .output)
                    if output.truncated != nil || output.text.count > ToolTextBlock.maxCharacters {
                        Text("Sortie tronquée.").font(ZCodeTypography.metadata).foregroundStyle(.secondary)
                    }
                }
                if let error = call.error {
                    Text(error.message).font(ZCodeTypography.metadata).foregroundStyle(.red)
                }
            }
        } label: {
            // Une seule ligne : nom de l'outil puis commande ou chemin, tronqués (cartes compactes, comme Claude Code).
            HStack(spacing: 6) {
                statusIcon.font(ZCodeTypography.toolIcon)
                Text(call.toolName).font(ZCodeTypography.toolName).layoutPriority(1)
                if let summary = summaryText, !summary.isEmpty {
                    Text(summary).font(ZCodeTypography.toolSummary).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let diff, diff.additions + diff.deletions > 0 {
                    Text("+\(diff.additions) −\(diff.deletions)").font(ZCodeTypography.toolDiff).foregroundStyle(.secondary)
                        .fixedSize()                                  // seul le résumé se comprime
                }
                if let timing {
                    ToolDurationLabel(timing: timing)
                }
                if let statusText {
                    Text(statusText).font(ZCodeTypography.toolStatus).foregroundStyle(.secondary).fixedSize()
                }
            }
            .lineLimit(1)
            .accessibilityLabel([call.toolName, summaryText, subagent?.statusLabel ?? call.status.label, finishedDuration].compactMap { $0 }
                                    .joined(separator: ", "))
        }
    }

    /// Durée figée lue par VoiceOver ; `nil` pendant l'exécution.
    private var finishedDuration: String? {
        if case .finished = timing { timing?.label(now: .now) } else { nil }
    }

    @ViewBuilder private var statusIcon: some View {
        if let subagent {
            // Même statut que le texte et VoiceOver : celui du sous-agent (un sous-agent en arrière-plan court encore).
            switch subagent.status {
            case "running": ProgressView().controlSize(.mini)
            case "success": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case "failed": Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case "cancelled": Image(systemName: "slash.circle").foregroundStyle(.secondary)
            default: toolStatusIcon
            }
        } else {
            toolStatusIcon
        }
    }

    @ViewBuilder private var toolStatusIcon: some View {
        switch call.status {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "slash.circle").foregroundStyle(.secondary)
        case .pendingApproval: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        default: ProgressView().controlSize(.mini)
        }
    }
}

/// Commande, entrée ou sortie d'une carte d'outil : les `LinePreview.cardLineCount` premières lignes, puis
/// « Afficher les N lignes » qui déplie le reste et devient « Réduire » (état local, perdu quand la cellule quitte la
/// liste). « Copier » prend toujours le texte entier.
private struct ToolTextBlock: View {
    enum Part {
        case command, input, output

        /// Complément des libellés VoiceOver : « Afficher les N lignes de la sortie », « Réduire la sortie ».
        var ofPart: String {
            switch self {
            case .command: "de la commande"
            case .input: "de l'entrée"
            case .output: "de la sortie"
            }
        }

        var thePart: String {
            switch self {
            case .command: "la commande"
            case .input: "l'entrée"
            case .output: "la sortie"
            }
        }

        var moreIdentifier: String { self == .output ? "tool-output-more" : "tool-input-more" }
    }

    /// Affichage borné : une commande bavarde ne doit pas figer la liste.
    static let maxCharacters = 20_000

    let language: String?
    let text: String
    let part: Part
    private let preview: LinePreview
    @State private var showsAll = false

    init(language: String?, text: String, part: Part) {
        self.language = language
        self.text = text
        self.part = part
        preview = String(text.prefix(Self.maxCharacters)).linePreview()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CodeBlock(language: language, code: showsAll ? String(text.prefix(Self.maxCharacters)) : preview.shown,
                      copyText: text, style: .compact)
            if preview.hiddenLineCount > 0 {
                Button(showsAll ? "Réduire" : preview.showAllLabel) { showsAll.toggle() }
                    .font(ZCodeTypography.metadata)
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showsAll ? "Réduire \(part.thePart)" : "\(preview.showAllLabel) \(part.ofPart)")
                    .accessibilityIdentifier(part.moreIdentifier)
            }
        }
    }
}

struct SubagentView: View {
    let subagent: Subagent

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sous-agent \(subagent.subagentType) · \(subagent.status)").font(.callout.bold())
                if !subagent.summaryText.isEmpty {
                    Text(subagent.summaryText).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
            }
        } icon: {
            Image(systemName: "person.2")
        }
    }
}

struct MarkerView: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            VStack { Divider() }
            Text(label).font(.caption).foregroundStyle(.secondary).fixedSize()
            VStack { Divider() }
        }
    }
}

/// Élément que cette version de l'app ne sait pas afficher (ZCode plus récent) : contenu brut, et l'interface web.
struct UnsupportedCard: View {
    let kind: String
    let json: JSONValue
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            CodeBlock(language: "json", code: json.prettyText)
        } label: {
            Label("Élément ZCode non pris en charge (\(kind))", systemImage: "puzzlepiece.extension")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
