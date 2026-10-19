import SwiftUI
import ZCodeAppCore

/// Diff unifié coloré : séparateur par hunk, numéros de ligne quand l'hôte les fournit, défilement horizontal.
/// `maxLines` borne l'affichage (dock, carte d'outil) ; le reste est annoncé.
struct DiffView: View {
    let file: FileDiff
    var maxLines = 400
    /// Police des lignes : `ZCodeTypography.toolDiff` dans une carte d'outil.
    var lineFont: Font = .caption.monospaced()

    var body: some View {
        let shown = file.limited(toLines: maxLines)
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.hunks.enumerated()), id: \.offset) { index, hunk in
                        if let header = hunk.header {
                            Text(header)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                        } else if index > 0 {
                            Text("⋯").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 6)
                        }
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            DiffLineRow(line: line, numbered: shown.isNumbered, font: lineFont)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            if shown.omittedLines > 0 {
                Text("\(shown.omittedLines) lignes non affichées").font(.caption).foregroundStyle(.secondary)
            }
            if file.truncated {
                Text("Diff tronqué par l'hôte : les compteurs portent sur le fichier entier.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diff-view")
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let numbered: Bool
    let font: Font

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if numbered {
                Text(line.oldNumber.map(String.init) ?? "").frame(minWidth: 30, alignment: .trailing)
                Text(line.newNumber.map(String.init) ?? "").frame(minWidth: 30, alignment: .trailing)
            }
            Text(prefix).frame(width: 10)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .meta ? .secondary : .primary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(font)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var prefix: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        case .meta: "\\"
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: .green.opacity(0.15)
        case .removed: .red.opacity(0.15)
        case .context, .meta: .clear
        }
    }
}

/// Chemin d'un fichier et ses compteurs `+a −d`.
struct DiffStatsLabel: View {
    let path: String
    let additions: Int
    let deletions: Int
    /// `ZCodeTypography.toolDiff` dans une carte d'outil, comme les lignes du diff.
    var font: Font = .caption.monospaced()

    var body: some View {
        HStack(spacing: 6) {
            Text(path).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if additions > 0 { Text("+\(additions)").foregroundStyle(.green) }
            if deletions > 0 { Text("−\(deletions)").foregroundStyle(.red) }
        }
        .font(font)
    }
}
