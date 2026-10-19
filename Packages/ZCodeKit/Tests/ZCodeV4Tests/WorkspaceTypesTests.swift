import Foundation
import Testing
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

/// Valeur d'un enregistrement de `git-files` choisi par son préfixe (`"001"`…).
private func gitFiles(_ prefix: String) throws -> JSONValue {
    try #require(try Fixtures.records(in: "v3.15.1/git-files").first { $0.file.hasPrefix(prefix) }).value
}

/// Valeur d'un enregistrement de `git-actions` (mutations réelles sur le dépôt de `Probe/make-actions-repo.sh`).
private func gitActions(_ prefix: String) throws -> JSONValue {
    try #require(try Fixtures.records(in: "v3.15.1/git-actions").first { $0.file.hasPrefix(prefix) }).value
}

struct WorkspaceTypesTests {
    @Test func etatDuDepot() throws {
        let result = try GitRefreshResult(json: gitFiles("001"))
        #expect(result.summary.isRepository)
        #expect(result.summary.branchName == "main")
        #expect(result.summary.trackingBranchName == nil)
        #expect(result.summary.isDirty)
        #expect(result.stagedChanges.map(\.workspaceRelativePath) == ["renamed.txt", "src/app.swift"])
        #expect(result.stagedChanges.map(\.kind) == [.renamed, .modified])
        #expect(result.stagedChanges.allSatisfy { $0.isStaged })
        #expect(result.unstagedChanges.map(\.workspaceRelativePath) == ["README.md", "logo.bin", "new.txt"])
        let untracked = try #require(result.unstagedChanges.last)
        #expect(untracked.section == .untracked && untracked.isUntracked && untracked.added == 2)
        #expect(untracked.path == "/private/tmp/zcode-fixture-repo/new.txt")
        #expect(Set((result.stagedChanges + result.unstagedChanges).map(\.id)).count == 5)
    }

    @Test func horsDepotSansErreur() throws {
        let result = try GitRefreshResult(json: gitFiles("007"))
        #expect(!result.summary.isRepository)
        #expect(result.summary.isGitAvailable)
        #expect(result.stagedChanges.isEmpty && result.unstagedChanges.isEmpty)
    }

    @Test func changementsTolerants() throws {
        let result = try GitRefreshResult(json: .object(["unstagedChanges": .array([
            .object(["path": .string("/r/a"), "kind": .string("typechange"), "section": .string("unstaged")]),
            .object(["kind": .string("modified")]),                                   // sans chemin : ignoré
            .object(["path": .string("/r/dossier/"), "section": .string("untracked")]),
        ])]))
        #expect(result.unstagedChanges.map(\.kind.rawValue) == ["typechange", "modified"])
        #expect(result.unstagedChanges.map(\.workspaceRelativePath) == ["/r/a", "/r/dossier/"])
        #expect(result.unstagedChanges.last?.isDirectory == true)
        #expect(result.summary.isRepository == false)
        #expect(throws: V4DecodingError.self) { try GitRefreshResult(json: .array([])) }
    }

    @Test func diffs() throws {
        let readme = try GitDiffResult(json: gitFiles("002"))
        #expect(readme.availability == .patch)
        #expect(readme.patch?.hasPrefix("diff --git a/README.md b/README.md\n") == true)
        let untracked = try GitDiffResult(json: gitFiles("003"))
        #expect(untracked.patch?.hasPrefix("--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@") == true)
        let binary = try GitDiffResult(json: gitFiles("004"))
        #expect(binary.availability == .binary && binary.patch == nil)
        #expect(binary.summary == "Binary diff is not previewable.")
        let renamed = try GitDiffResult(json: gitFiles("006"))
        #expect(renamed.patch?.contains("new file mode 100644") == true)
        #expect(try GitDiffResult(json: .object([:])).availability == .unavailable)
        #expect(throws: V4DecodingError.self) { try GitDiffResult(json: .null) }
    }

    @Test func dossiers() throws {
        let visible = try FileEntry.list(json: gitFiles("008"))
        #expect(visible.map(\.name) == ["src", "big.txt", "logo.bin", "new.txt", "README.md", "renamed.txt"])
        #expect(visible.first?.isDirectory == true)
        #expect(visible.dropFirst().allSatisfy { !$0.isDirectory && !$0.isSymbolicLink })
        let all = try FileEntry.list(json: gitFiles("009"))
        #expect(Array(all.map(\.name).prefix(3)) == [".git", "src", ".hidden"])
        #expect(try FileEntry.list(json: .array([.object(["name": .string("x")])])).isEmpty)   // sans chemin
        #expect(throws: V4DecodingError.self) { try FileEntry.list(json: .object([:])) }
    }

    @Test func lecturesDeFichiers() throws {
        let readme = try FileTextSlice(json: gitFiles("011"))
        #expect(readme.content.hasPrefix("# Démo\n"))
        #expect(!readme.truncated && !readme.isBinary && readme.totalBytes == 51)
        let big = try FileTextSlice(json: gitFiles("012"))
        #expect(big.truncated && big.totalBytes == 298_500 && big.bytesRead == 262_144)
        #expect(big.content.hasSuffix("\u{FFFD}"))                 // « é » coupé à la borne de 256 Kio
        let binary = try FileTextSlice(json: gitFiles("013"))
        #expect(binary.isBinary && binary.content.isEmpty && binary.totalBytes == 300)
        #expect(throws: V4DecodingError.self) { try FileTextSlice(json: .object(["path": .string("/x")])) }
    }

    @Test func recherche() throws {
        let matches = try WorkspaceFileMatch.list(json: gitFiles("015"))
        #expect(matches.first?.relativePath == "src/app.swift")
        #expect(matches.contains { $0.isDirectory && $0.name == "src" })
        #expect(matches.contains { $0.relativePath == ".hidden" })            // l'hôte ne masque rien
        #expect(throws: V4DecodingError.self) { try WorkspaceFileMatch.list(json: .null) }
    }

    func toolCallRow(output: JSONValue) throws -> ConversationRow {
        try #require(ConversationRow(json: .object([
            "rowId": .number(42), "kind": .string("toolCall"), "turnId": .string("t1"),
            "toolCallId": .string("call_a"), "toolName": .string("Edit"), "status": .string("success"),
            "inputText": .string("{}"), "output": output,
        ])))
    }

    @Test func diffDeLHotePourUnEditTermine() throws {
        let row = try toolCallRow(output: .object([
            "text": .string("The file /repo/src/app.ts has been updated."),
            "display": .object([
                "kind": .string("file_diff"), "filePath": .string("/repo/src/app.ts"),
                "additions": .number(1), "deletions": .number(1), "truncated": .bool(true),
                "structuredPatch": .array([.object([
                    "oldStart": .number(10), "oldLines": .number(3), "newStart": .number(10), "newLines": .number(3),
                    "lines": .array([.string(" a"), .string("-b"), .string("+c"), .string(" d")]),
                ])]),
            ]),
        ]))
        guard case .toolCall(let call) = row.content else { Issue.record("toolCall attendu"); return }
        let diff = try #require(call.output?.fileDiff)
        #expect(diff.filePath == "/repo/src/app.ts")
        #expect(diff.additions == 1 && diff.deletions == 1 && diff.truncated)
        #expect(diff.hunks.first?.oldStart == 10)
        #expect(diff.hunks.first?.lines == [" a", "-b", "+c", " d"])
        // Un delta de sortie ne fait pas perdre le diff.
        let appended = row.appending(" Fin.", at: .outputText)
        guard case .toolCall(let updated) = appended.content else { Issue.record("toolCall attendu"); return }
        #expect(updated.output?.text.hasSuffix("Fin.") == true)
        #expect(updated.output?.fileDiff == diff)
    }

    @Test func displayInconnuOuIllisible() throws {
        for display in [
            JSONValue.object(["kind": .string("bash_output"), "output": .string("ok"), "truncated": .bool(false)]),
            .object(["kind": .string("file_diff"), "filePath": .string("/x")]),          // sans structuredPatch
            .string("?"),
        ] {
            let row = try toolCallRow(output: .object(["text": .string("ok"), "display": display]))
            guard case .toolCall(let call) = row.content else { Issue.record("la ligne doit rester un toolCall"); return }
            #expect(call.output?.text == "ok")
            #expect(call.output?.fileDiff == nil)
        }
    }

    @Test func resultatsDesMutations() throws {
        let blocked = try GitBranchMutationResult(json: gitActions("006"))
        #expect(!blocked.ok && blocked.issues.first?.code == .trackedChangesWouldBeOverwritten)
        #expect(blocked.issues.first?.paths == ["README.md"])
        #expect(blocked.summary?.branchName == "main")
        #expect(try GitBranchMutationResult(json: gitActions("007")).issues.first?.code == .targetBranchNotFound)
        #expect(try GitBranchMutationResult(json: gitActions("008")).issues.first?.code == .invalidBranchName)
        #expect(try GitCommitResult(json: gitActions("009")).commitHash.count == 40)
        let firstPush = try GitPushResult(json: gitActions("013"))
        #expect(firstPush.setUpstream && firstPush.remoteName == "origin" && firstPush.trackingBranchName == "origin/main")
        #expect(try !GitPushResult(json: gitActions("014")).setUpstream)
        let branches = try GitLocalBranchList(json: gitActions("012"))
        #expect(branches.branches.map(\.name) == ["main", "autre"] && branches.currentBranchName == "main")
        #expect(branches.branches.first?.isCurrent == true && branches.headRefType == "branch")
        let created = try GitBranchMutationResult(json: gitActions("015"))
        #expect(created.ok && created.created && created.didChange && created.branchName == "feature/fixture")
        let generated = try GitGeneratedCommitMessage(json: gitActions("016"))
        #expect(!generated.message.isEmpty && generated.model == "GLM-5.3")
    }

    @Test func codeDIssueInconnuGarde() throws {
        let json: JSONValue = .object(["ok": .bool(false), "didChange": .bool(false), "created": .bool(false),
            "issues": .array([.object(["code": .string("nouveau-code"), "message": .string("x")])])])
        let result = try GitBranchMutationResult(json: json)
        #expect(result.issues.first?.code.rawValue == "nouveau-code" && result.summary == nil)
        #expect(throws: V4DecodingError.self) { try GitCommitResult(json: .object([:])) }
        #expect(throws: V4DecodingError.self) { try GitBranchMutationResult(json: .string("?")) }
    }
}
