import SwiftUI
import ZCodeAppCore

/// Lecture d'un fichier (256 premiers Kio) : numéros de ligne, Markdown rendu avec bascule vers la source.
struct FileView: View {
    let host: Host
    let workspace: String
    let path: String
    @Environment(AppModel.self) private var model
    @State private var content: FileContent?
    @State private var rendered = true

    private var isMarkdown: Bool { ["md", "markdown"].contains(URL(filePath: path).pathExtension.lowercased()) }

    var body: some View {
        Group {
            switch content {
            case nil:
                ProgressView("Lecture du fichier…")
            case .failed(let reason)?:
                ContentUnavailableView("Lecture impossible", systemImage: "exclamationmark.triangle", description: Text(reason))
            case .binary(let size)?:
                ContentUnavailableView("Fichier binaire", systemImage: "doc.zipper", description: Text(
                    "\(Int64(size).formatted(.byteCount(style: .file))) : pas d'aperçu dans l'app."))
            case .text(let lines, let truncated, let size)?:
                if isMarkdown && rendered {
                    ScrollView {
                        MarkdownText(markdown: lines.joined(separator: "\n")).padding()
                    }
                    .safeAreaInset(edge: .top) { if truncated { TruncatedBanner(size: size) } }
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        CodeLines(lines: lines).padding()
                    }
                    .safeAreaInset(edge: .top) { if truncated { TruncatedBanner(size: size) } }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-content")
        .navigationTitle(URL(filePath: path).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isMarkdown, case .text? = content {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Affichage", selection: $rendered) {
                        Text("Aperçu").tag(true)
                        Text("Source").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .task { content = await model.fileBrowser(for: host, workspace: workspace).read(path) }
    }
}

private struct TruncatedBanner: View {
    let size: Int

    var body: some View {
        Label("Aperçu limité aux 256 premiers Kio (fichier de \(Int64(size).formatted(.byteCount(style: .file)))).",
              systemImage: "scissors")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.bar)
    }
}

/// Lignes numérotées ; une `LazyVStack` pour qu'un fichier de 256 Kio ne soit pas mis en page d'un bloc.
private struct CodeLines: View {
    let lines: [String]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)").foregroundStyle(.secondary).frame(minWidth: 36, alignment: .trailing)
                    Text(line.isEmpty ? " " : line).fixedSize(horizontal: true, vertical: false)
                }
                .font(.caption.monospaced())
            }
        }
        .textSelection(.enabled)
    }
}
