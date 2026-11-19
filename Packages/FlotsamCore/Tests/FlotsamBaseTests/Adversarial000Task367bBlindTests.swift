import Foundation
import Testing

// TASK-367 / TASK-368 / TASK-515 second blind QA round (Worf). Attacks the regex-vs-division heuristic (`regex_start`),
// the left identifier boundaries, and the USTRING view list in bin/check-architecture.sh with shapes the first round and
// the builder's own tests do not hold. Expected values are literals (exit statuses, booleans), never the script's expressions.
// The harness is AdvLintHarness (Adversarial000Tests.swift); `reportsFatal` looks for the fatalError rule's own message so a
// fixture that fails for another reason (a force unwrap) cannot satisfy it.

@Suite("8A TASK-367b blind lint attack")
struct Adversarial000Task367bBlindTests {
    private func status(_ source: String) async throws -> Int32 {
        try await AdvLintHarness.exitStatus(for: source)
    }

    private func reports(_ source: String, _ message: String) async throws -> Bool {
        try await AdvLintHarness.run(source).output.contains(message)
    }

    // OC: FR-000-02. TASK-368/515. Mutants that turn it red: the line-start-only guard (`if (!atstart) return 0`) removed, `regex_start` returning 1 for every `?` or `!` (the operand test
    // deleted), or the keyword test removed from the `?`/`!` branch (`try?` then a quote hides the call).
    @Test("a real fatalError next to a `/` is never hidden by optional chaining, ??, a ternary, a prefix !, try? or as?")
    func realFatalErrorStaysVisible() async throws {
        let shapes = [
            "let a = x?.y ?? fatalError(\"x\")", "let a = c ? fatalError(\"x\") : 1", "let a = c ? 1 : fatalError(\"x\")",
            "let a = !fatalError(\"x\")", "let a = try? fatalError(\"x\")", "let a = x as? Int ?? fatalError(\"x\")",
            "let a = \"\\(fatalError(\"x\"))\"", "let a = \"\\(x ?? fatalError(\"x\"))\"",
            "let a = foo(/abc/, fatalError(\"x\"))", "let a = /abc/; fatalError(\"x\")",
            "let a = x /\n fatalError(\"x\") /\n 2", "let a = x\n / fatalError(\"x\")", "let a = x /fatalError(\"x\") / 2",
            "let a = try? /\"/; fatalError(\"x\")", "let a = x as! /\"/; fatalError(\"x\")",
            // an INLINE division whose second slash ends the line stays a division (only a line-start / may be read as a statement regex)
            "let a = total/g(fatalError(\"x\"))/\n    2", "let a = f()/g(fatalError(\"x\"))/\n    2",
        ]
        for shape in shapes {
            // given a banned call in a line that also holds a `/`, when linted, then the fatalError rule reports it
            #expect(try await reports(shape, "fatalError/precondition without"), "\(shape.debugDescription)")
        }
    }

    // OC: FR-000-02. TASK-515. Mutants: `$`, `)`, `]` or a digit dropped from the operand class before a postfix `!`/`?`.
    @Test("a postfix ! or ? after a $0, tuple index, call, subscript or non-ASCII identifier ends the operand")
    func postfixOperandClasses() async throws {
        let tail = "/n + g(fatalError(\"x\"))/2"
        for operand in ["$0!", "a.0!", "f(x)!", "a![0]!", "héllo!", "$0?", "a.0?", "héllo?", "a[0]?"] {
            // given an operand then `!`/`?` then a division with a real call in the second operand, when linted, then it is reported
            #expect(try await reports("let r = \(operand)\(tail)", "fatalError/precondition without"), "inline \(operand)")
            #expect(try await reports("let r = \(operand)\n    \(tail)", "fatalError/precondition without"), "line-start \(operand)")
        }
    }

    // OC: FR-000-02. TASK-368. Mutant: the division reading applied everywhere at line start (the pre-2ed68a4 regression), or the
    // regex reading applied everywhere (the 2ed68a4 behaviour). Valid code must exit 0, with no false positive.
    @Test("valid regex literals and valid divisions exit 0")
    func validCodeIsNotFlagged() async throws {
        let shapes = [
            "let a = b\n    /c\n    /d", "let a = b\n    / c", "let a = b?\n    /c", "let a = b?.c\n    /d + 1", "let a = !(b)/2",
            "let a = Regex {\n  Capture(.digit)\n  /,/\n  ChoiceOf { /a/ ; /b/ }\n}",
            "let a = Regex {\n  Capture(.digit)\n  /x!/\n}", "let a = c ? 1 : /fatalError(x)/", "let a = c ? /fatalError(x)/ : 1",
            "let a = x ?? /fatalError(x)/", "let a = a ?? b ?? /fatalError(x)/", "let a = x != /fatalError(x)/",
            "let a = \"\\(a/b) fatalError(x)\"", "let r = x as? /fatalError(x)/",
            "let r = x.filter { !/fatalError(x)/.matches($0) }", "let r = x.filter { !$0.isEmpty && !/fatalError(x)/.matches($0) }",
            "let r = x.first(where: !/fatalError(x)/.matches)", "if !/re/.matches(x) {}",
            "let a = Regex {\n  Capture(.digit)\n  /fatalError(x)/ // why\n}",
        ]
        for shape in shapes {
            // given valid code, when linted, then it passes
            #expect(try await status(shape) == 0, "\(shape.debugDescription)")
        }
    }

    // OC: FR-000-05. TASK-367. Mutant: the boundary class loses `_`, a digit, `$` or non-ASCII; or the rule loses the `.` member case.
    @Test("a view name needs a non-identifier character on its left; a member access still counts")
    func viewNameBoundaryClasses() async throws {
        // given a custom type whose name merely ends in a view name, when linted, then it passes
        for shape in ["let v = _Text(\"x\")", "let v = T9Text(\"x\")", "let v = $Text(\"x\")", "let v = éText(\"x\")", "let v = TextText(\"x\")",
                      "let v = éURLSession.shared", "let s = x1localizedDescriptionFoo", "let s = MySparkle()"] {
            #expect(try await status(shape) == 0, "\(shape.debugDescription)")
        }
        // given the real name behind a member access, an optional chain, a brace or a split line, when linted, then it fails
        for shape in ["let v = x.Text(\"x\")", "let v = x?.Text(\"x\")", "let v = ZStack {Text(\"x\")}", "let v = Text\n(\"x\")",
                      "let v = Text(\n    verbatim:\n \"x\")", "let v = Text(#\"x\"#)", "let v = Text(\"x\" + \"y\")",
                      "let s = e.localizedDescriptionFoo", "let s = e.`localizedDescription`", "let s = Sparkle.x", "let s = Sparkles.x",
                      "let s = a\n.URLSession.shared"] {
            #expect(try await status(shape) == 1, "\(shape.debugDescription)")
        }
        // given non-literal arguments, when linted, then they pass
        for shape in ["let v = Text(name)", "let v = Text(LocalizedStringKey(k))", "let v = Text(FlotsamStrings.text(forKey: \"ui.a.b\"))"] {
            #expect(try await status(shape) == 0, "\(shape.debugDescription)")
        }
    }

    // MARK: pinned gaps (withKnownIssue). Each is a lint blind spot found by this round; none is a regression of the accepted limit.

    // OC: FR-000-05. TASK-367 regression, closed by TASK-516. Before the left boundary `Button(`/`MenuButton(` matched by substring; these two
    // real SwiftUI views (both take a LocalizedStringKey title, per the macOS SDK swiftinterface) end in a listed name, so they are listed by name.
    @Test("TASK-516: SwiftUI views MenuButton and NewDocumentButton are linted by USTRING")
    func suffixedViewsMissingFromList() async throws {
        for shape in ["let v = MenuButton(\"Go\") { }", "let v = NewDocumentButton(\"New\") { }"] {
            #expect(try await status(shape) == 1, "\(shape.debugDescription)")
        }
    }

    // OC: FR-000-05. Closed by TASK-516. SwiftUI views with a LocalizedStringKey title init that were in no pattern (SDK interface scan).
    @Test("TASK-516: TableColumn, SharePreview and AccessibilityRotorEntry titles are linted")
    func neverListedViews() async throws {
        for shape in ["let v = TableColumn(\"Name\", value: \\.name)", "let v = SharePreview(\"Name\")",
                      "let v = AccessibilityRotorEntry(\"Name\", id: i)"] {
            #expect(try await status(shape) == 1, "\(shape.debugDescription)")
        }
    }

    // OC: FR-000-02. TASK-368. A RegexBuilder literal followed by a method chain is read as a division after an operand line, so its text is
    // linted as code (a false positive; pre-existing since 2ed68a4, outside the three TASK-368 shapes).
    @Test("KNOWN TASK-368: a statement-position regex with a method chain after it is linted as code")
    func statementRegexWithMethodChain() async throws {
        let code = try await status("let a = Regex {\n  Capture(.digit)\n  /fatalError(x)/.ignoresCase()\n}")
        withKnownIssue("`/.../.method()` after an operand line is read as division") {
            #expect(code == 0)
        }
    }

    // OC: FR-000-02. TASK-368. The accepted limit's siblings: the same shape with a trailing comment, after `?`, and after `)`/`]`.
    // Pinned next to the existing divisionEndingInSlashAtLineEnd decision so the whole family is one recorded ambiguity.
    @Test("KNOWN TASK-368: the accepted line-end-slash limit also covers a trailing comment, a ? and a ) or ] operand")
    func divisionEndingInSlashFamily() async throws {
        for shape in ["let r = total\n    /g(fatalError(\"x\"))/ // c", "let r = total?\n    /g(fatalError(\"x\"))/",
                      "let r = f()\n    /g(fatalError(\"x\"))/", "let r = a[0]\n    /g(fatalError(\"x\"))/"] {
            let code = try await status(shape)
            withKnownIssue("operand then line-start /...../ closing the line is read as a regex: \(shape.debugDescription)") {
                #expect(code == 1)
            }
        }
    }

    // OC: FR-000-02. TASK-368. A backtick-quoted identifier is not in the operand class before a postfix `?`, so the `/` after it is a regex.
    @Test("KNOWN TASK-368: a backtick-quoted identifier before a postfix ? is not an operand")
    func backtickOperandBeforePostfixQuestion() async throws {
        let code = try await status("let r = a.`class`?/n + g(fatalError(\"x\"))/2")
        withKnownIssue("operand class has no backtick") {
            #expect(code == 1)
        }
    }
}
