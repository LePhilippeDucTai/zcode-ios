import Foundation
import ZCodeV4

/// Ligne affichable d'un diff.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case context, added, removed
        /// `\ No newline at end of file` : n'appartient ni à l'ancien ni au nouveau fichier.
        case meta
    }

    public let kind: Kind
    /// Texte sans le préfixe `+`, `-` ou espace ; la ligne entière pour une méta-ligne.
    public let text: String
    /// Numéros dans l'ancien et le nouveau fichier ; `nil` pour un diff calculé par l'app (fragment de fichier).
    public let oldNumber: Int?
    public let newNumber: Int?
}

/// Hunk prêt à afficher.
public struct DiffHunkLines: Equatable, Sendable {
    /// `@@ -a,b +c,d @@ …` ; `nil` pour un diff calculé par l'app (pas de numéros fiables).
    public let header: String?
    public let lines: [DiffLine]
}

/// Diff d'un fichier, quelle que soit sa source : patch texte de `git diff`, hunks structurés de l'hôte (tour, Edit
/// terminé) ou diff calculé par l'app (aperçu d'une autorisation).
public struct FileDiff: Equatable, Sendable {
    public var path: String?
    public var hunks: [DiffHunkLines] = []
    public var additions = 0
    public var deletions = 0
    /// Diff coupé par l'hôte (8 hunks / 160 lignes pour un Edit) : les compteurs restent ceux du fichier entier.
    public var truncated = false
    /// Lignes retirées par l'app pour l'affichage (`limited(toLines:)`).
    public var omittedLines = 0
    public var isNewFile = false
    public var isDeletedFile = false

    init(path: String?) {
        self.path = path
    }

    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }

    /// Numéros de ligne réels (hunks de l'hôte ou de `git diff`), par opposition à un diff calculé par l'app.
    public var isNumbered: Bool { hunks.contains { $0.header != nil } }

    /// Garde les `maxLines` premières lignes (hunks entiers, puis le début du suivant) ; le reste est compté dans
    /// `omittedLines`. Un long diff ne doit pas figer le dock ni la liste.
    /// Chaque ligne gardée est aussi coupée à `String.maxDisplayedLineLength` caractères (fichier minifié sur une ligne).
    public func limited(toLines maxLines: Int) -> FileDiff {
        var kept: [DiffHunkLines] = []
        var remaining = maxLines
        for hunk in hunks where remaining > 0 {
            let lines = hunk.lines.prefix(remaining).map { line in
                DiffLine(kind: line.kind, text: line.text.clippedForDisplay, oldNumber: line.oldNumber, newNumber: line.newNumber)
            }
            kept.append(DiffHunkLines(header: hunk.header, lines: lines))
            remaining -= lines.count
        }
        var copy = self
        copy.hunks = kept
        copy.omittedLines = omittedLines + max(lineCount - maxLines, 0)
        return copy
    }
}

/// Lecture des diffs de l'hôte.
public enum UnifiedDiff {
    /// Patch texte de `git diff` (plusieurs fichiers possibles ; patch synthétique d'un fichier non suivi sans
    /// `diff --git`). Les en-têtes hors hunk (`index`, `similarity`, modes) sont ignorés ; CRLF toléré.
    public static func parse(_ patch: String) -> [FileDiff] {
        var parser = PatchParser()
        for line in patch.textLines {
            parser.consume(line)
        }
        return parser.finish()
    }

    /// Hunks structurés de l'hôte (diff d'un tour, `file_diff` d'un Edit), numérotés depuis `oldStart` / `newStart`.
    /// `additions` / `deletions` : compteurs de l'hôte, qui l'emportent sur ceux des lignes reçues (diff tronqué).
    public static func file(path: String?, hunks: [DiffHunk], truncated: Bool = false,
                            additions: Int? = nil, deletions: Int? = nil) -> FileDiff {
        var file = FileDiff(path: path)
        for hunk in hunks {
            var old = hunk.oldStart
            var new = hunk.newStart
            let lines = hunk.lines.map { classify($0, old: &old, new: &new) }
            file.additions += lines.count { $0.kind == .added }
            file.deletions += lines.count { $0.kind == .removed }
            // jsdiff garde `oldStart` / `newStart` + 1 pour un côté vide ; l'en-tête canonique affiche 0.
            let oldStart = hunk.oldLines == 0 ? max(hunk.oldStart - 1, 0) : hunk.oldStart
            let newStart = hunk.newLines == 0 ? max(hunk.newStart - 1, 0) : hunk.newStart
            file.hunks.append(DiffHunkLines(header: "@@ -\(oldStart),\(hunk.oldLines) +\(newStart),\(hunk.newLines) @@",
                                            lines: lines))
        }
        if let additions { file.additions = additions }
        if let deletions { file.deletions = deletions }
        file.truncated = truncated
        return file
    }

    /// Ligne d'un hunk → ligne affichable ; avance les numéros de l'ancien et du nouveau fichier.
    static func classify(_ raw: String, old: inout Int, new: inout Int) -> DiffLine {
        switch raw.first {
        case "+":
            let line = DiffLine(kind: .added, text: String(raw.dropFirst()), oldNumber: nil, newNumber: new)
            new += 1
            return line
        case "-":
            let line = DiffLine(kind: .removed, text: String(raw.dropFirst()), oldNumber: old, newNumber: nil)
            old += 1
            return line
        case "\\":
            return DiffLine(kind: .meta, text: raw, oldNumber: nil, newNumber: nil)
        default:
            // Espace de contexte ; une ligne vide (blancs de fin retirés par un outil) est un contexte vide.
            let line = DiffLine(kind: .context, text: raw.first == " " ? String(raw.dropFirst()) : raw,
                                oldNumber: old, newNumber: new)
            old += 1
            new += 1
            return line
        }
    }
}

/// `@@ -a[,b] +c[,d] @@` (une longueur absente vaut 1).
private struct HunkRange {
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int

    init?(_ line: String) {
        guard let match = line.prefixMatch(of: /@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) else { return nil }
        oldStart = Int(match.1) ?? 0
        oldLines = match.2.flatMap { Int($0) } ?? 1
        newStart = Int(match.3) ?? 0
        newLines = match.4.flatMap { Int($0) } ?? 1
    }
}

/// Lecture ligne à ligne d'un patch texte. Les longueurs annoncées par chaque `@@` délimitent le hunk : une ligne
/// `--- a/x` qui suit un hunk complet ouvre un nouveau fichier au lieu d'être lue comme une suppression.
private struct PatchParser {
    private var files: [FileDiff] = []
    private var current: FileDiff?
    private var header: String?
    private var lines: [DiffLine] = []
    private var old = 0
    private var new = 0
    private var remainingOld = 0
    private var remainingNew = 0
    private var oldPath: String?

    mutating func consume(_ line: String) {
        if header != nil, remainingOld > 0 || remainingNew > 0 || line.hasPrefix("\\") {
            let diffLine = UnifiedDiff.classify(line, old: &old, new: &new)
            switch diffLine.kind {
            case .added:
                remainingNew -= 1
                current?.additions += 1
            case .removed:
                remainingOld -= 1
                current?.deletions += 1
            case .context:
                remainingOld -= 1
                remainingNew -= 1
            case .meta:
                break
            }
            lines.append(diffLine)
            return
        }
        closeHunk()
        if line.hasPrefix("diff --git ") {
            closeFile()
            current = FileDiff(path: Self.headerPath(line))
        } else if let range = HunkRange(line) {
            if current == nil { current = FileDiff(path: oldPath) }
            header = line
            (old, new, remainingOld, remainingNew) = (range.oldStart, range.newStart, range.oldLines, range.newLines)
        } else if line.hasPrefix("--- ") {
            // Patch sans `diff --git` (fichier non suivi, plusieurs fichiers) : un `---` après des hunks ouvre un fichier.
            if current?.hunks.isEmpty == false { closeFile() }
            if current == nil { current = FileDiff(path: nil) }
            oldPath = Self.side(line)
            if oldPath == nil { current?.isNewFile = true }
        } else if line.hasPrefix("+++ ") {
            if current == nil { current = FileDiff(path: nil) }
            if let side = Self.side(line) {
                current?.path = side
            } else {
                current?.isDeletedFile = true
                if current?.path == nil { current?.path = oldPath }
            }
        } else if line.hasPrefix("new file mode") {
            current?.isNewFile = true
        } else if line.hasPrefix("deleted file mode") {
            current?.isDeletedFile = true
        }
    }

    mutating func finish() -> [FileDiff] {
        closeFile()
        return files
    }

    private mutating func closeHunk() {
        guard let header else { return }
        current?.hunks.append(DiffHunkLines(header: header, lines: lines))
        self.header = nil
        lines = []
    }

    private mutating func closeFile() {
        closeHunk()
        if let current { files.append(current) }
        current = nil
        oldPath = nil
    }

    /// `diff --git a/x b/x` → `x`.
    private static func headerPath(_ line: String) -> String? {
        guard let range = line.range(of: " b/", options: .backwards) else { return nil }
        return String(line[range.upperBound...])
    }

    /// `--- a/x` / `+++ b/x` → `x` ; `/dev/null` → `nil` ; une date après une tabulation est retirée.
    private static func side(_ line: String) -> String? {
        var path = String(line.dropFirst(4))
        if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }
        if path == "/dev/null" { return nil }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { path.removeFirst(2) }
        return path
    }
}

/// Diff ligne à ligne calculé par l'app : l'hôte n'en fournit aucun pour un Edit ou un Write en attente
/// d'autorisation (l'interface web le calcule aussi). Sans numéros de ligne : `old_string` / `new_string` ne sont
/// qu'un fragment du fichier.
public enum LineDiff {
    /// Au-delà, pas de calcul de diff : un Write de plusieurs Mio arrive entier dans la demande d'autorisation.
    public static let maxCharacters = 200_000
    public static let maxLines = 4_000

    public static func between(_ old: String, _ new: String, path: String?) -> FileDiff {
        let oldLines = old.textLines
        let newLines = new.textLines
        let tooLarge = old.utf8.count + new.utf8.count > maxCharacters || oldLines.count + newLines.count > maxLines
        let lines = tooLarge
            ? oldLines.map { DiffLine(kind: .removed, text: $0, oldNumber: nil, newNumber: nil) }
                + newLines.map { DiffLine(kind: .added, text: $0, oldNumber: nil, newNumber: nil) }
            : diffed(oldLines, newLines)
        var file = FileDiff(path: path)
        file.additions = lines.count { $0.kind == .added }
        file.deletions = lines.count { $0.kind == .removed }
        if !lines.isEmpty { file.hunks = [DiffHunkLines(header: nil, lines: lines)] }
        return file
    }

    /// Myers (`CollectionDifference`) : retraits avant ajouts au même endroit, comme `git diff`.
    private static func diffed(_ old: [String], _ new: [String]) -> [DiffLine] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [DiffLine] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                result.append(DiffLine(kind: .removed, text: old[i], oldNumber: nil, newNumber: nil))
                i += 1
            } else if j < new.count, inserted.contains(j) {
                result.append(DiffLine(kind: .added, text: new[j], oldNumber: nil, newNumber: nil))
                j += 1
            } else if i < old.count, j < new.count {
                result.append(DiffLine(kind: .context, text: old[i], oldNumber: nil, newNumber: nil))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return result
    }
}
