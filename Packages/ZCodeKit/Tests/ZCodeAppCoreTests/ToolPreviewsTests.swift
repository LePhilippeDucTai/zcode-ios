import Foundation
import Testing
import ZCodeAppCore
import ZCodeV4
import ZCodeWire

private struct NotAToolCall: Error {}

struct ToolPreviewsTests {
    func prompt(_ toolName: String, _ detail: JSONValue) throws -> PermissionPrompt {
        PermissionPrompt(try V4JSON.decode(PermissionRequest.self, from: .object([
            "kind": .string("permission"), "toolCallId": .string("call"), "toolName": .string(toolName),
            "summary": .string("\(toolName) requires approval"), "detail": detail,
            "options": .array([.object(["optionId": .string("allowOnce"), "label": .string("Allow once"), "kind": .string("allowOnce")])]),
        ])))
    }

    func toolCall(_ toolName: String, input: JSONValue, output: JSONValue? = nil) throws -> ToolCall {
        var object: [String: JSONValue] = [
            "rowId": .number(1), "kind": .string("toolCall"), "toolCallId": .string("c"), "toolName": .string(toolName),
            "status": .string("success"), "inputText": .string(""), "input": input,
        ]
        if let output { object["output"] = output }
        guard case .toolCall(let call) = try #require(ConversationRow(json: .object(object))).content else { throw NotAToolCall() }
        return call
    }

    @Test func editEnAttente() throws {
        let preview = try prompt("Edit", .object([
            "file_path": .string("/r/src/app.ts"), "old_string": .string("const a = 1;"), "new_string": .string("const a = 2;"),
        ])).preview
        guard case .diff(let diff)? = preview else { Issue.record("diff attendu"); return }
        #expect(diff.path == "/r/src/app.ts")
        #expect(diff.additions == 1 && diff.deletions == 1 && !diff.isNumbered)
    }

    @Test func writeEnormeBorne() throws {
        let content = String(repeating: "ligne de texte\n", count: 200_000)              // 3 Mo, jamais tronqué par l'hôte
        let preview = try prompt("Write", .object(["file_path": .string("/r/gros.txt"), "content": .string(content)])).preview
        guard case .diff(let diff)? = preview else { Issue.record("diff attendu"); return }
        #expect(diff.additions == 200_000 && diff.deletions == 0)
        #expect(diff.limited(toLines: 200).lineCount == 200)
    }

    @Test func ligneGeanteCoupeeALAffichage() throws {
        let minified = String(repeating: "{\"a\":1},", count: 400_000)                 // 3,2 Mo sur une seule ligne
        let preview = try prompt("Write", .object(["file_path": .string("/r/min.json"), "content": .string(minified)])).preview
        guard case .diff(let diff)? = preview else { Issue.record("diff attendu"); return }
        let line = try #require(diff.limited(toLines: 200).hunks.first?.lines.first)
        #expect(line.text.count < 2_100)
        #expect(line.text.hasSuffix("… (3200000 caractères)"))
        #expect(diff.additions == 1)
    }

    @Test func commandeAdresseEtAutres() throws {
        #expect(try prompt("Bash", .object(["command": .string("npm test"), "description": .string("Lance les tests")])).preview
            == .command("npm test", description: "Lance les tests"))
        #expect(try prompt("WebFetch", .object(["url": .string("https://example.com"), "prompt": .string("Résume")])).preview
            == .fetch(url: "https://example.com", prompt: "Résume"))
        #expect(try prompt("ApplyPatch", .object(["patch_text": .string("*** Begin Patch")])).preview == .text("*** Begin Patch"))
        #expect(try prompt("mcp__github__create_issue", .object(["title": .string("x")])).preview == nil)   // comme le web
        guard case .text(let json)? = try prompt("CreateWorkflow", .object(["steps": .number(3)])).preview else {
            Issue.record("JSON attendu"); return
        }
        #expect(json.contains("\"steps\""))
        #expect(try prompt("Edit", .object([:])).preview == nil)
    }

    @Test func editTermineAvecDiffDeLHote() throws {
        let call = try toolCall("Edit",
            input: .object(["file_path": .string("/r/a.ts"), "old_string": .string("x"), "new_string": .string("y")]),
            output: .object(["text": .string("ok"), "display": .object([
                "kind": .string("file_diff"), "filePath": .string("/r/a.ts"), "additions": .number(1), "deletions": .number(1),
                "structuredPatch": .array([.object([
                    "oldStart": .number(7), "oldLines": .number(1), "newStart": .number(7), "newLines": .number(1),
                    "lines": .array([.string("-x"), .string("+y")]),
                ])]),
            ])]))
        let diff = try #require(call.fileDiff)
        #expect(diff.isNumbered && diff.path == "/r/a.ts")
        #expect(diff.hunks.first?.lines.first?.oldNumber == 7)
    }

    @Test func writeTermineSansDiffDeLHote() throws {
        let call = try toolCall("Write", input: .object(["file_path": .string("/r/new.md"), "content": .string("# Titre\nTexte\n")]),
                                output: .object(["text": .string("File created successfully at: /r/new.md")]))
        let diff = try #require(call.fileDiff)
        #expect(!diff.isNumbered && diff.additions == 2 && diff.deletions == 0)
    }

    @Test func displayInconnuIgnore() throws {
        let call = try toolCall("Bash", input: .object(["command": .string("ls")]), output: .object([
            "text": .string("a"),
            "display": .object(["kind": .string("bash_output"), "output": .string("a"), "truncated": .bool(true)]),
        ]))
        #expect(call.fileDiff == nil)
    }

    @Test func cheminRelatifAuProjet() {
        #expect(WorkspacePaths.display("/Users/p/claude/src/a.swift", in: "/Users/p/claude") == "src/a.swift")
        #expect(WorkspacePaths.display("/Users/p/claude/src/a.swift", in: "/Users/p/claude/") == "src/a.swift")
        #expect(WorkspacePaths.display("/tmp/x", in: "/Users/p/claude") == "/tmp/x")
        #expect(WorkspacePaths.display("/Users/p/claudette/a", in: "/Users/p/claude") == "/Users/p/claudette/a")
    }

    @Test func commandeShellCopieeTelleQuelle() throws {
        let command = "cat <<'EOF' > notes.txt\nligne 1\nEOF\nswift test && \\\n  git status"
        let bash = try toolCall("Bash", input: .object([
            "command": .string(command), "description": .string("Écrit les notes"), "timeout": .number(120_000),
        ]))
        #expect(bash.shellCommand == command)                                     // à l'identique, sans « $ » ni JSON
        #expect(try toolCall("Bash", input: .object(["command": .string("   ")])).shellCommand == nil)
        #expect(try toolCall("Read", input: .object(["file_path": .string("/r/a.swift")])).shellCommand == nil)
    }
}
