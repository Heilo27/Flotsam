import Foundation
import Testing

// TASK-516 blind QA (Worf). The five SwiftUI views added to the USTRING view list, each attacked with the real call shapes
// (trailing closure, extra labelled args, space before the paren, literal split over lines, raw and multi-line strings,
// interpolation), the left identifier boundary, non-literal arguments, and mentions in comments and string literals.
// Expected values are literals (exit statuses). The harness is AdvLintHarness (Adversarial000Tests.swift).

@Suite("8A TASK-516 blind USTRING view-list attack")
struct Adversarial000Task516BlindTests {
    private static let views = ["MenuButton", "NewDocumentButton", "TableColumn", "SharePreview", "AccessibilityRotorEntry"]

    private func status(_ source: String) async throws -> Int32 {
        try await AdvLintHarness.exitStatus(for: source)
    }

    // OC: FR-000-05 / TASK-516 AC1. Mutant that turns it red: any one name dropped from the view list in bin/check-architecture.sh
    // (the matching view's iteration reports 0 and the message names the view and the shape).
    @Test("each added view fails USTRING in every real call shape")
    func eachViewIsLintedInEveryShape() async throws {
        for view in Self.views {
            let shapes = [
                "let v = \(view)(\"Go\") { }", "let v = \(view) (\"Go\")", "let v = \(view)(\n    \"Go\")",
                "let v = \(view)(\"Go\", value: \\.name) { }", "let v = \(view)(\"Go\", id: i)", "let v = \(view)(#\"Go\"#)",
                "let v = \(view)(\"\"\"\n    Go\n    \"\"\")", "let v = \(view)(\"Go \\(count)\")",
                "let v = x.\(view)(\"Go\")", "let v = x?.\(view)(\"Go\")", "let v = Table { \(view)(\"Go\") { r in r.n } }",
            ]
            for shape in shapes {
                // given a literal title passed to the view, when linted, then USTRING fails the run
                #expect(try await status(shape) == 1, "\(view): \(shape.debugDescription)")
            }
        }
    }

    // OC: FR-000-05 / TASK-516 AC2. Mutants: the left boundary removed from the view pattern (a custom type ending in a view name
    // then matches), or a trailing-boundary regression that lets `MenuButtons(` / `TableColumns(` match.
    @Test("a custom type that merely contains an added view name, or a non-literal argument, still exits 0")
    func lookalikesAndNonLiteralsPass() async throws {
        for view in Self.views {
            let shapes = [
                "let v = My\(view)(\"Go\")", "let v = _\(view)(\"Go\")", "let v = \(view)2(\"Go\")", "let v = \(view)s(\"Go\")",
                "let v = \(view)Style(\"Go\")", "let v = é\(view)(\"Go\")",
                "let v = \(view)(name)", "let v = \(view)(LocalizedStringKey(k)) { }",
                "let v = \(view)(FlotsamStrings.text(forKey: \"ui.a.b\"))", "let v = \(view)(1) { r in r.n }",
                "let v = \(view)\n", "let v = \(view).self",
            ]
            for shape in shapes {
                // given a lookalike identifier or a non-literal title, when linted, then it passes
                #expect(try await status(shape) == 0, "\(view): \(shape.debugDescription)")
            }
        }
    }

    // OC: FR-000-05 / TASK-516. Mutant: comment and string stripping skipped before the USTRING scan (the name inside prose would be reported).
    @Test("an added view name inside a comment or a string literal is not a call")
    func mentionsInProseAreIgnored() async throws {
        for view in Self.views {
            for shape in ["// \(view)(\"Go\")", "/* \(view)(\"Go\") */", "let s = \"\(view)(\\\"Go\\\")\"", "/// Use \(view)(\"Go\") here."] {
                // given the call text only in a comment or string, when linted, then it passes
                #expect(try await status(shape) == 0, "\(view): \(shape.debugDescription)")
            }
        }
    }

    // OC: FR-000-05 / TASK-516 AC1 vs the neighbours. Survivor identity: the old list still fires and an unlisted look-alike
    // SwiftUI name does not (mutant: the new names appended by corrupting the alternation, e.g. a dropped `|` merging two names).
    @Test("the alternation still fires for the pre-existing names and for names adjacent to the new ones")
    func neighbouringNamesKeepTheirVerdict() async throws {
        for view in ["Text", "Button", "UtilityWindow", "Menu", "Window"] {
            #expect(try await status("let v = \(view)(\"Go\")") == 1, "\(view) stays linted")
        }
        // given names formed by gluing two adjacent list entries, when linted, then they are not matched
        for view in ["UtilityWindowMenuButton", "MenuButtonNewDocumentButton", "NewDocumentButtonTableColumn",
                     "TableColumnSharePreview", "SharePreviewAccessibilityRotorEntry"] {
            #expect(try await status("let v = \(view)(\"Go\")") == 0, "\(view) is one custom identifier")
        }
    }
}
