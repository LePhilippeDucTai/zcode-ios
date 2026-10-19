import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Hunk structuré tel que l'hôte l'envoie (jsdiff).
func diffHunk(_ oldStart: Int, _ oldLines: Int, _ newStart: Int, _ newLines: Int, _ lines: [String]) throws -> DiffHunk {
    try V4JSON.decode(DiffHunk.self, from: .object([
        "oldStart": .number(Double(oldStart)), "oldLines": .number(Double(oldLines)),
        "newStart": .number(Double(newStart)), "newLines": .number(Double(newLines)),
        "lines": .array(lines.map(JSONValue.string)),
    ]))
}

/// Valeur d'un enregistrement réel de `git-files` choisi par son préfixe (`"002"`…).
func gitFilesRecord(_ prefix: String) throws -> JSONValue {
    try #require(try Fixtures.records(in: "v3.15.1/git-files").first { $0.file.hasPrefix(prefix) }).value
}

/// Valeur d'un enregistrement réel de `git-actions` (mutations) choisi par son préfixe.
func gitActionsRecord(_ prefix: String) throws -> JSONValue {
    try #require(try Fixtures.records(in: "v3.15.1/git-actions").first { $0.file.hasPrefix(prefix) }).value
}

struct FileDiffTests {
    func patch(_ prefix: String) throws -> String {
        try #require(gitFilesRecord(prefix)["patch"]?.stringValue)
    }

    @Test func patchGitReel() throws {
        let files = UnifiedDiff.parse(try patch("002"))
        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.path == "README.md")
        #expect(!file.isNewFile && !file.isDeletedFile && file.isNumbered)
        #expect(file.additions == 2 && file.deletions == 1)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.header == "@@ -1,5 +1,6 @@")
        #expect(hunk.lines.map(\.kind) == [.context, .context, .context, .removed, .added, .context, .added])
        #expect(hunk.lines.map(\.oldNumber) == [1, 2, 3, 4, nil, 5, nil])
        #expect(hunk.lines.map(\.newNumber) == [1, 2, 3, nil, 4, 5, 6])
        #expect(hunk.lines[3].text == "Ligne 2" && hunk.lines[4].text == "Ligne 2 modifiée")
        #expect(hunk.lines[1].text == "")                                // ligne vide de contexte
    }

    @Test func fichierNonSuiviSansDiffGit() throws {
        let file = try #require(UnifiedDiff.parse(try patch("003")).first)
        #expect(file.path == "new.txt")
        #expect(file.isNewFile)
        #expect(file.hunks.first?.header == "@@ -0,0 +1,2 @@")
        #expect(file.hunks.first?.lines.map(\.newNumber) == [1, 2])
        #expect(file.hunks.first?.lines.map(\.oldNumber) == [nil, nil])
        #expect(file.additions == 2 && file.deletions == 0)
    }

    @Test func renommageIndexeVuCommeNouveauFichier() throws {
        let file = try #require(UnifiedDiff.parse(try patch("006")).first)
        #expect(file.path == "renamed.txt")
        #expect(file.isNewFile && file.additions == 3)
    }

    @Test func plusieursFichiersCRLFEtFinDeLigne() {
        let patch = "diff --git a/a.txt b/a.txt\r\nindex 1..2 100644\r\n--- a/a.txt\r\n+++ b/a.txt\r\n@@ -1 +1 @@\r\n-x\r\n"
            + "\\ No newline at end of file\r\n+y\r\n\\ No newline at end of file\r\n"
            + "diff --git a/b.txt b/b.txt\r\ndeleted file mode 100644\r\n--- a/b.txt\r\n+++ /dev/null\r\n@@ -1,2 +0,0 @@\r\n-1\r\n-2\r\n"
        let files = UnifiedDiff.parse(patch)
        #expect(files.map(\.path) == ["a.txt", "b.txt"])
        let first = files[0]
        #expect(first.hunks.first?.header == "@@ -1 +1 @@")
        #expect(first.hunks.first?.lines.map(\.kind) == [.removed, .meta, .added, .meta])
        #expect(first.hunks.first?.lines.map(\.text) == ["x", "\\ No newline at end of file", "y", "\\ No newline at end of file"])
        #expect(first.hunks.first?.lines.first?.oldNumber == 1)
        #expect(first.additions == 1 && first.deletions == 1)
        #expect(files[1].isDeletedFile && files[1].deletions == 2 && files[1].additions == 0)
        #expect(files[1].hunks.first?.header == "@@ -1,2 +0,0 @@")
    }

    @Test func patchsVidesOuSansHunk() {
        #expect(UnifiedDiff.parse("").isEmpty)
        let modeOnly = UnifiedDiff.parse("diff --git a/x.sh b/x.sh\nold mode 100644\nnew mode 100755\n")
        #expect(modeOnly.map(\.path) == ["x.sh"])
        #expect(modeOnly.first?.hunks.isEmpty == true)
    }

    @Test func hunksStructuresDeLHote() throws {
        let file = UnifiedDiff.file(path: "/r/x.swift", hunks: [
            try diffHunk(10, 3, 10, 4, [" a", "-b", "+c", "+d", " e"]),
            try diffHunk(1, 0, 1, 2, ["+x", "+y"]),                 // côté vide : jsdiff garde oldStart à 1
        ])
        #expect(file.hunks.map(\.header) == ["@@ -10,3 +10,4 @@", "@@ -0,0 +1,2 @@"])
        #expect(file.hunks[0].lines.map(\.oldNumber) == [10, 11, nil, nil, 12])
        #expect(file.hunks[0].lines.map(\.newNumber) == [10, nil, 11, 12, 13])
        #expect(file.hunks[1].lines.map(\.newNumber) == [1, 2])
        #expect(file.additions == 4 && file.deletions == 1 && !file.truncated)
        // Diff coupé par l'hôte : ses compteurs (fichier entier) l'emportent sur ceux des lignes reçues.
        let cut = UnifiedDiff.file(path: "/r/x.swift", hunks: [try diffHunk(1, 1, 1, 1, ["-a", "+b"])],
                                   truncated: true, additions: 40, deletions: 2)
        #expect(cut.additions == 40 && cut.deletions == 2 && cut.truncated)
    }

    @Test func diffLocalDUnEdit() {
        let file = LineDiff.between("a\nb\nc", "a\nB\nc\nd", path: "/r/x.swift")
        #expect(file.path == "/r/x.swift")
        #expect(file.hunks.count == 1 && file.hunks.first?.header == nil && !file.isNumbered)
        #expect(file.hunks.first?.lines.map(\.kind) == [.context, .removed, .added, .context, .added])
        #expect(file.hunks.first?.lines.map(\.text) == ["a", "b", "B", "c", "d"])
        #expect(file.hunks.first?.lines.allSatisfy { $0.oldNumber == nil && $0.newNumber == nil } == true)
        #expect(file.additions == 2 && file.deletions == 1)
        #expect(LineDiff.between("même", "même", path: nil).additions == 0)
    }

    @Test func writeToutEnAjout() {
        let file = LineDiff.between("", "x\ny\n", path: "/r/new.md")
        #expect(file.hunks.first?.lines.map(\.kind) == [.added, .added])
        #expect(file.additions == 2 && file.deletions == 0)
        #expect(LineDiff.between("", "", path: nil).hunks.isEmpty)
    }

    @Test func tropGrosPourUnDiff() {
        let big = String(repeating: "ligne\n", count: 50_000)          // 300 000 caractères > maxCharacters
        let written = LineDiff.between("", big, path: "/r/gros.txt")
        #expect(written.additions == 50_000)
        let shown = written.limited(toLines: 200)
        #expect(shown.lineCount == 200 && shown.omittedLines == 49_800)
        // Edit géant : pas de diff, tout l'ancien retiré puis tout le nouveau ajouté.
        let edited = LineDiff.between(big, big + "fin", path: nil)
        #expect(edited.deletions == 50_000 && edited.additions == 50_001)
        #expect(edited.hunks.first?.lines.first?.kind == .removed)
    }

    @Test func limitationEntreDeuxHunks() throws {
        let file = UnifiedDiff.file(path: nil, hunks: [
            try diffHunk(1, 3, 1, 3, [" a", " b", " c"]), try diffHunk(10, 3, 10, 3, [" x", " y", " z"]),
        ])
        let shown = file.limited(toLines: 4)
        #expect(shown.hunks.map(\.lines.count) == [3, 1])
        #expect(shown.lineCount == 4 && shown.omittedLines == 2)
        #expect(file.limited(toLines: 10) == file)
    }
}
