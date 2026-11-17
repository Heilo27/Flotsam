import Foundation
import Testing
@testable import FlotsamBase

// FRD-000 lint and API-surface checks (OC-0001, OC-0002, OC-0003, OC-0034, OC-0049 unit half, OC-0073 compile half).
//
// The lint is `bin/check-architecture.sh`. Each test runs it against a throwaway COPY of the shipped tree (bin, App,
// Package.swift, Sources, project.yml), injects exactly one change into the copy, and reads the script's real exit
// status and output. The live tree is never touched. Expected values are literals: file paths, injected text, counts.

// MARK: - Harness

/// One local-disk snapshot of the tree the lint inspects, made once per test process. The repo lives on an external
/// drive where copying the ~66 files takes ~0.25 s; copying it afresh in each of ~17 concurrent tests held a
/// cooperative-pool thread for ~0.5 s apiece and starved unrelated tasks (the SystemClock sleeper, OC-0077). Each
/// `ScratchTree` now copies from this snapshot on the internal disk instead. The actor makes the first caller do the
/// copy while the others suspend (no thread blocked).
/// Path of the live snapshot, for the process-exit sweep (a C `atexit` handler cannot capture; it reads this global).
/// Written once, by the actor below, before any reader exists.
nonisolated(unsafe) private var snapshotPathForExit: UnsafeMutablePointer<CChar>?

private actor TreeSnapshot {
    static let shared = TreeSnapshot()
    private var cached: URL?

    func root() throws -> URL {
        if let cached { return cached }
        let fm = FileManager.default
        // Stale snapshots from killed runs (older than an hour) are swept before a new one is made.
        let temp = fm.temporaryDirectory
        for entry in (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where entry.lastPathComponent.hasPrefix("flotsam-lint-snapshot-") {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < Date(timeIntervalSinceNow: -3600) { try? fm.removeItem(at: entry) }
        }
        let snapshot = temp.appendingPathComponent("flotsam-lint-snapshot-\(UUID().uuidString)")
        let repo = Repo.root()
        try fm.createDirectory(at: snapshot.appendingPathComponent("Packages/FlotsamCore"), withIntermediateDirectories: true)
        try fm.copyItem(at: repo.appendingPathComponent("bin"), to: snapshot.appendingPathComponent("bin"))
        try fm.copyItem(at: repo.appendingPathComponent("App"), to: snapshot.appendingPathComponent("App"))
        try fm.copyItem(at: repo.appendingPathComponent("project.yml"), to: snapshot.appendingPathComponent("project.yml"))
        let pkg = repo.appendingPathComponent("Packages/FlotsamCore")
        let dest = snapshot.appendingPathComponent("Packages/FlotsamCore")
        try fm.copyItem(at: pkg.appendingPathComponent("Sources"), to: dest.appendingPathComponent("Sources"))
        try fm.copyItem(at: pkg.appendingPathComponent("Package.swift"), to: dest.appendingPathComponent("Package.swift"))
        snapshotPathForExit = strdup(snapshot.path)
        atexit { if let path = snapshotPathForExit { try? FileManager.default.removeItem(atPath: String(cString: path)) } }
        cached = snapshot
        return snapshot
    }
}

/// A scratch copy of the tree the lint inspects. `discard()` removes it.
private struct ScratchTree {
    let root: URL

    init() async throws {
        let fm = FileManager.default
        let snapshot = try await TreeSnapshot.shared.root()
        root = fm.temporaryDirectory.appendingPathComponent("flotsam-lint-\(UUID().uuidString)")
        try fm.copyItem(at: snapshot, to: root)
    }

    func discard() { try? FileManager.default.removeItem(at: root) }

    func lint() async throws -> ProcessResult {
        try await runProcess("/bin/bash", [root.appendingPathComponent("bin/check-architecture.sh").path])
    }

    func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func write(_ text: String, to relativePath: String) throws {
        try text.write(to: root.appendingPathComponent(relativePath), atomically: true, encoding: .utf8)
    }

    /// Appends one line to a file and returns the 1-based line number it landed on.
    @discardableResult
    func append(_ line: String, to relativePath: String) throws -> Int {
        var text = try contents(relativePath)
        if !text.hasSuffix("\n") { text += "\n" }
        let lineNumber = text.filter { $0 == "\n" }.count + 1
        try write(text + line + "\n", to: relativePath)
        return lineNumber
    }

    var swiftSourceCount: Int {
        let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("Packages/FlotsamCore/Sources"), includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }.count
    }
}

private let sources = "Packages/FlotsamCore/Sources"

// MARK: - OC-0001, OC-0002

@Suite struct LintHarnessTests {
    /// OC-0001. Given the shipped sources, when the lint runs, then it exits 0, prints the pass line and names no
    /// violation. The same script fails the mutated copies in the tests below, so a no-op script cannot pass both.
    @Test("OC-0001 lint reports 0 violations on the shipped sources")
    func shippedSourcesAreClean() async throws {
        let tree = try await ScratchTree()
        defer { tree.discard() }
        #expect(tree.swiftSourceCount >= 28, "precondition: the copy holds the module sources")
        let result = try await tree.lint()
        #expect(result.status == 0, "lint exit status; output: \(result.output)")
        #expect(result.output.contains("architecture checks passed"))
        #expect(!result.output.contains("ARCH VIOLATION"))
    }

    struct Mutant: Sendable, CustomTestStringConvertible {
        let name: String
        let path: String
        let line: String
        var testDescription: String { name }
    }

    static let oc0002Mutants: [Mutant] = [
        Mutant(name: "try! on a pasteboard read", path: "\(sources)/FlotsamBase/Ports/Ports.swift",
               line: "let mutantPasteboardRead = try! Data(contentsOf: URL(fileURLWithPath: \"/dev/null\"))"),
        Mutant(name: "as! on a database row value", path: "\(sources)/FlotsamStorage/Database/FlotsamDatabase.swift",
               line: "let mutantRowValue = (\"x\" as Any) as! Int"),
        Mutant(name: "fatalError in a non-Fatal path", path: "\(sources)/FlotsamBase/Errors/ErrorReporter.swift",
               line: "func mutantNonFatalPath() { fatalError(\"not a fatal site\") }"),
    ]

    /// OC-0002. Given a clean copy and one injected forbidden construct, when the lint runs, then it fails and names
    /// the injected file and line; given the mutation reverted, the lint passes again.
    @Test("OC-0002 each injected try!, as!, fatalError fails the lint at its line and reverting passes", arguments: oc0002Mutants)
    func injectedConstructFailsLint(mutant: Mutant) async throws {
        let tree = try await ScratchTree()
        defer { tree.discard() }
        let original = try tree.contents(mutant.path)
        #expect(try await tree.lint().status == 0, "precondition: the copy lints clean before the mutation")

        let line = try tree.append(mutant.line, to: mutant.path)
        let mutated = try await tree.lint()
        #expect(mutated.status == 1, "mutated lint exit status")
        #expect(mutated.output.contains("\(mutant.path):\(line):"), "lint names the injected line \(line); output: \(mutated.output)")

        try tree.write(original, to: mutant.path)
        let reverted = try await tree.lint()
        #expect(reverted.status == 0, "reverted lint exit status; output: \(reverted.output)")
    }

    /// OC-0002 negative. Given a fatalError annotated `fatal-ok:` and one named only in a comment, when the lint runs,
    /// then it passes: the rule is the annotation, not the word.
    @Test("OC-0002 an annotated fatalError and a commented one are not violations")
    func annotatedFatalErrorIsAllowed() async throws {
        let tree = try await ScratchTree()
        defer { tree.discard() }
        let path = "\(sources)/FlotsamBase/Errors/ErrorReporter.swift"
        try tree.append("func mutantAnnotated() { fatalError(\"unreachable\") } // fatal-ok: unreachable invariant", to: path)
        try tree.append("// fatalError(\"named only in a comment\")", to: path)
        let result = try await tree.lint()
        #expect(result.status == 0, "lint exit status; output: \(result.output)")
        #expect(!result.output.contains("fatalError/precondition"))
    }

    static let forceUnwrapShapes: [Mutant] = [
        Mutant(name: "unwrap after a call: x()!.y", path: "\(sources)/FlotsamBase/Model/Model.swift", line: "let mutantA = UUID(uuidString: \"x\")!.uuidString"),
        Mutant(name: "unwrap at end of line: arr.first!", path: "\(sources)/FlotsamBase/Model/Model.swift", line: "let mutantB = [1].first!"),
        Mutant(name: "unwrap after a subscript at end of line: row[\"k\"]!", path: "\(sources)/FlotsamBase/Model/Model.swift", line: "let mutantC = [String: Int]()[\"k\"]!"),
        Mutant(name: "unwrap after a subscript before an operator: row[\"k\"]! + 1", path: "\(sources)/FlotsamBase/Model/Model.swift", line: "let mutantD = [String: Int]()[\"k\"]! + 1"),
    ]

    /// OC-0001 force-unwrap rule. Given a force-unwrap of an optional (the shape a database row or pasteboard read
    /// takes), when the lint runs, then it fails and names the line. Subscript shapes are the ones a row value uses.
    @Test("OC-0001 injected force-unwrap fails the lint at its line", arguments: forceUnwrapShapes)
    func forceUnwrapFailsLint(mutant: Mutant) async throws {
        let tree = try await ScratchTree()
        defer { tree.discard() }
        #expect(try await tree.lint().status == 0, "precondition: clean before the mutation")
        let line = try tree.append(mutant.line, to: mutant.path)
        let result = try await tree.lint()
        #expect(result.status == 1, "mutated lint exit status")
        #expect(result.output.contains("\(mutant.path):\(line):"), "lint names line \(line); output: \(result.output)")
    }

    // MARK: OC-0034

    private static let loggingMutants: [Mutant] = [
        Mutant(name: "print", path: "\(sources)/FlotsamBase/Model/Model.swift", line: "func mutantPrint() { print(\"clip\") }"),
        Mutant(name: "NSLog", path: "\(sources)/FlotsamBase/Strings/FlotsamStrings.swift", line: "func mutantNSLog() { NSLog(\"clip\") }"),
        Mutant(name: "dump", path: "\(sources)/FlotsamBase/Errors/ErrorRingBuffer.swift", line: "func mutantDump() { dump(1) }"),
    ]

    private func mutatedLoggingTree() async throws -> (tree: ScratchTree, lines: [(path: String, line: Int)]) {
        let tree = try await ScratchTree()
        var lines: [(String, Int)] = []
        for mutant in Self.loggingMutants { lines.append((mutant.path, try tree.append(mutant.line, to: mutant.path))) }
        return (tree, lines)
    }

    /// OC-0034 clean half. Given the unmodified sources, when the lint runs, then no print, NSLog or dump is flagged.
    @Test("OC-0034 unmodified sources have 0 print, NSLog or dump occurrences flagged")
    func cleanSourcesHaveNoLoggingCalls() async throws {
        let tree = try await ScratchTree()
        defer { tree.discard() }
        #expect(tree.swiftSourceCount >= 28, "precondition: the copy holds the module sources")
        let result = try await tree.lint()
        #expect(result.status == 0)
        #expect(!result.output.contains("print/NSLog/dump"))
    }

    /// OC-0034 detection. Given one print, one NSLog and one dump injected in three files, when the lint runs, then it
    /// fails and names all three lines.
    @Test("OC-0034 the lint names each injected print, NSLog and dump line")
    func lintNamesEachLoggingCall() async throws {
        let (tree, lines) = try await mutatedLoggingTree()
        defer { tree.discard() }
        let result = try await tree.lint()
        #expect(result.status == 1)
        #expect(lines.count == 3, "precondition: three mutations injected")
        for (path, line) in lines {
            #expect(result.output.contains("\(path):\(line):"), "lint names \(path):\(line); output: \(result.output)")
        }
    }

    /// OC-0034 count. Given one print, one NSLog and one dump, when the lint runs, then it reports 3 violations.
    /// The contract counts hits; the script prints one violation per rule, so it reports "1 violation(s)" here.
    @Test("OC-0034 the lint reports 3 violations for 3 injected logging calls")
    func lintReportsThreeViolations() async throws {
        let (tree, _) = try await mutatedLoggingTree()
        defer { tree.discard() }
        let result = try await tree.lint()
        #expect(result.output.contains("3 violation"), "summary line; output tail: \(result.output.split(separator: "\n").last ?? "")")
    }

    // MARK: OC-0003 lint half

    static let publicThrowsMutants: [Mutant] = [
        Mutant(name: "public throws in a module file", path: "\(sources)/FlotsamBase/Ports/Adapters.swift", line: "public func mutantThrows() throws {}"),
        Mutant(name: "public throws in Ports.swift (the file the lint exempts)", path: "\(sources)/FlotsamBase/Ports/Ports.swift", line: "public func mutantPortsThrows() throws {}"),
        Mutant(name: "package throws in a module file", path: "\(sources)/FlotsamBase/Ports/Adapters.swift", line: "package func mutantPackageThrows() throws {}"),
        Mutant(name: "open throws in a module file", path: "\(sources)/FlotsamBase/Ports/Adapters.swift", line: "open func mutantOpenThrows() throws {}"),
    ]

    /// OC-0003 lint half. Given a public function declared `throws` added to the sources, when the lint runs, then it
    /// fails and names the line, wherever the function sits.
    @Test("OC-0003 an injected public throws function fails the lint at its line", arguments: publicThrowsMutants)
    func publicThrowsFailsLint(mutant: Mutant) async throws {
        let tree = try await ScratchTree()
        defer { tree.discard() }
        #expect(try await tree.lint().status == 0, "precondition: clean before the mutation")
        let line = try tree.append(mutant.line, to: mutant.path)
        let result = try await tree.lint()
        #expect(result.status == 1, "mutated lint exit status")
        #expect(result.output.contains("\(mutant.path):\(line):"), "lint names line \(line); output: \(result.output)")
    }

    // MARK: OC-0049 unit half

    /// OC-0049 unit half, shipped manifests. Given the shipped Package.resolved, Package.swift and project.yml, then
    /// the only third-party package is GRDB and the Xcode project lists only the local FlotsamCore package.
    @Test("OC-0049 manifests declare GRDB as the only third-party package")
    func onlyGRDBIsThirdParty() async throws {
        let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: Repo.packageRoot().appendingPathComponent("Package.resolved"))) as? [String: Any]
        let pins = resolved?["pins"] as? [[String: Any]] ?? []
        #expect(pins.compactMap { $0["identity"] as? String } == ["grdb.swift"], "Package.resolved identities")

        let manifest = try String(contentsOf: Repo.packageRoot().appendingPathComponent("Package.swift"), encoding: .utf8)
        let urls = manifest.components(separatedBy: "\n").compactMap { line -> String? in
            guard let range = line.range(of: #".package(url: ""#) else { return nil }
            return String(line[range.upperBound...].prefix { $0 != "\"" })
        }
        #expect(urls == ["https://github.com/groue/GRDB.swift.git"], "Package.swift remote packages")

        let project = try String(contentsOf: Repo.root().appendingPathComponent("project.yml"), encoding: .utf8).components(separatedBy: "\n")
        let start = try #require(project.firstIndex(of: "packages:"), "project.yml has a packages: block")
        let block = project[(start + 1)...].prefix { $0.hasPrefix(" ") }
        #expect(block.filter { $0.hasPrefix("  ") && !$0.hasPrefix("   ") }.map { $0.trimmingCharacters(in: .whitespaces) } == ["FlotsamCore:"], "project.yml packages")
    }

    static let sdkMutants: [Mutant] = [
        Mutant(name: "Sentry package in Package.swift", path: "Packages/FlotsamCore/Package.swift", line: "    .package(url: \"https://github.com/getsentry/sentry-cocoa.git\", from: \"8.0.0\"),"),
        Mutant(name: "Sentry package in project.yml", path: "project.yml", line: "  Sentry: { url: \"https://github.com/getsentry/sentry-cocoa\", from: \"8.0.0\" }"),
        Mutant(name: "import Sentry in a module source", path: "\(sources)/FlotsamBase/Model/Model.swift", line: "import Sentry"),
        Mutant(name: "import FirebaseCrashlytics in the app", path: "App/Flotsam/FlotsamApp.swift", line: "import FirebaseCrashlytics"),
    ]

    /// OC-0049 unit half, lint. Given a crash or analytics SDK added to a manifest or imported in source, when the lint
    /// runs, then it fails and names the line.
    @Test("OC-0049 an injected crash or analytics SDK fails the lint at its line", arguments: sdkMutants)
    func sdkFailsLint(mutant: Mutant) async throws {
        let tree = try await ScratchTree()
        defer { tree.discard() }
        #expect(try await tree.lint().status == 0, "precondition: clean before the mutation")
        let line = try tree.append(mutant.line, to: mutant.path)
        let result = try await tree.lint()
        #expect(result.status == 1, "mutated lint exit status")
        #expect(result.output.contains("\(mutant.path):\(line):"), "lint names line \(line); output: \(result.output)")
    }
}

// MARK: - OC-0003 unit half: public API surface

/// One public function declaration found by `PublicAPI.functions(in:)`.
private struct PublicFunction {
    let file: String
    let line: Int
    let name: String
    let effects: String
    let returnType: String
}

/// A small declaration scanner (test-owned, independent of the lint script). It counts a `func` as public when it
/// carries `public`/`open`/`package`, or sits directly in a public protocol or public extension body. It
/// over-approximates (a `public func` inside an internal type counts) which is the safe direction for a ban.
private enum PublicAPI {
    static func functions(in source: String, file: String) -> [PublicFunction] {
        let lines = source.components(separatedBy: "\n").map(stripped)
        var found: [PublicFunction] = []
        var depth = 0
        var publicBodyDepths: [Int] = []
        var index = 0
        while index < lines.count {
            let code = lines[index]
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            let opens = code.filter { $0 == "{" }.count
            let closes = code.filter { $0 == "}" }.count

            let isContainer = trimmed.range(of: #"^(@\w+\s+)*(public|open)\s+(protocol|extension)\b"#, options: .regularExpression) != nil
                || trimmed.range(of: #"^(public|open)\s+(final\s+)?(protocol|extension)\b"#, options: .regularExpression) != nil
            if isContainer, opens > closes { publicBodyDepths.append(depth + 1) }

            if let funcRange = trimmed.range(of: #"(^|\s)func\s+"#, options: .regularExpression) {
                let modifiers = String(trimmed[..<funcRange.lowerBound])
                let hasPublic = modifiers.range(of: #"\b(public|open|package)\b"#, options: .regularExpression) != nil
                let hasHidden = modifiers.range(of: #"\b(private|fileprivate|internal)\b"#, options: .regularExpression) != nil
                let inPublicBody = publicBodyDepths.last == depth && !hasHidden
                if hasPublic || inPublicBody {
                    var declaration = trimmed
                    var cursor = index
                    while parenBalance(declaration) > 0, cursor + 1 < lines.count {
                        cursor += 1
                        declaration += " " + lines[cursor].trimmingCharacters(in: .whitespaces)
                    }
                    if let parsed = parse(declaration, file: file, line: index + 1) { found.append(parsed) }
                }
            }

            depth += opens - closes
            while let last = publicBodyDepths.last, depth < last { publicBodyDepths.removeLast() }
            index += 1
        }
        return found
    }

    private static func parenBalance(_ text: String) -> Int {
        text.filter { $0 == "(" }.count - text.filter { $0 == ")" }.count
    }

    /// Drops string literals and trailing comments so braces and keywords inside them are ignored.
    private static func stripped(_ line: String) -> String {
        var text = line.replacingOccurrences(of: #""(\\.|[^"\\])*""#, with: "\"\"", options: .regularExpression)
        if let comment = text.range(of: "//") { text = String(text[..<comment.lowerBound]) }
        return text
    }

    private static func parse(_ declaration: String, file: String, line: Int) -> PublicFunction? {
        guard let funcRange = declaration.range(of: #"func\s+"#, options: .regularExpression) else { return nil }
        let afterFunc = declaration[funcRange.upperBound...]
        let name = String(afterFunc.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        // Skip generics, then the balanced parameter list; what follows is effects (async, throws) and `-> Type`.
        guard let open = afterFunc.firstIndex(of: "(") else { return nil }
        var balance = 0
        var close = open
        for position in afterFunc[open...].indices {
            if afterFunc[position] == "(" { balance += 1 }
            if afterFunc[position] == ")" { balance -= 1; if balance == 0 { close = position; break } }
        }
        var tail = String(afterFunc[afterFunc.index(after: close)...])
        if let brace = tail.firstIndex(of: "{") { tail = String(tail[..<brace]) }
        let parts = tail.components(separatedBy: "->")
        let effects = parts[0].trimmingCharacters(in: .whitespaces)
        let returnType = parts.count > 1 ? parts[1...].joined(separator: "->").trimmingCharacters(in: .whitespaces) : ""
        return PublicFunction(file: file, line: line, name: name, effects: effects, returnType: returnType)
    }

    static func throwing(_ functions: [PublicFunction]) -> [String] {
        functions.filter { $0.effects.range(of: #"\b(re)?throws\b"#, options: .regularExpression) != nil }.map { "\($0.file):\($0.line) \($0.name)" }
    }

    /// A function that returns a `Result` must return `Result<_, FlotsamError>` (or `FlotsamResult<_>`).
    static func wrongResultError(_ functions: [PublicFunction]) -> [String] {
        functions.filter { function in
            let type = function.returnType
            let returnsResult = type.range(of: #"\bResult<"#, options: .regularExpression) != nil
            let isFlotsam = type.contains("FlotsamResult<") || (returnsResult && type.contains("FlotsamError"))
            return returnsResult && !isFlotsam
        }.map { "\($0.file):\($0.line) \($0.name)" }
    }

    static func shipped() throws -> [PublicFunction] {
        let enumerator = FileManager.default.enumerator(at: Repo.packageRoot().appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
        var all: [PublicFunction] = []
        for case let url as URL in enumerator ?? FileManager.default.enumerator(atPath: "/nonexistent")! where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            all += functions(in: source, file: url.lastPathComponent)
        }
        return all
    }
}

@Suite struct PublicAPISurfaceTests {
    /// OC-0003 scanner control. Given a synthetic source with known public throwing functions (in a public protocol, a
    /// struct, a multi-line signature and a public extension) and known non-offenders, when it is scanned, then exactly
    /// the offenders are listed. Without this, a scanner that finds nothing would pass the shipped-surface test.
    @Test("OC-0003 scanner finds public throws and wrong Result error types, and ignores the rest")
    func scannerFindsKnownOffenders() {
        let source = """
        public protocol P {
            func a() async throws
            func b() -> Int
        }
        public struct S {
            public func c() throws -> Int { 1 }
            func d() throws {}
            public func e(_ body: () throws -> Void) -> Int { 0 }
            public func g() -> Result<Int, MyErr> { fatalError() }
            public func h() -> FlotsamResult<Int> { fatalError() }
            public func m() -> Result<Int, FlotsamError> { fatalError() }
            private func i() throws {}
            public func j(
                x: Int
            ) throws {}
            public static func measure<Result>(_ body: () -> Result) -> Result { body() }
        }
        public extension S {
            func k() throws {}
            private func l() throws {}
        }
        extension S {
            func n() throws {}
        }
        """
        let functions = PublicAPI.functions(in: source, file: "synthetic.swift")
        #expect(Set(functions.map(\.name)) == ["a", "b", "c", "e", "g", "h", "m", "j", "measure", "k"], "public functions found")
        #expect(PublicAPI.throwing(functions).sorted() == ["synthetic.swift:13 j", "synthetic.swift:2 a", "synthetic.swift:6 c", "synthetic.swift:19 k"].sorted(), "public throws found")
        #expect(PublicAPI.wrongResultError(functions) == ["synthetic.swift:9 g"], "wrong Result error found")
    }

    /// OC-0003. Given every module's public functions, when their signatures are enumerated, then 0 public functions
    /// are declared `throws` (a throwing public function crosses its module boundary) and 0 return a `Result` whose
    /// error is not FlotsamError. Fallibility is read from the signature (`throws` or a `Result` return); an
    /// optional-returning lookup is not counted as fallible because the signature does not say it can fail.
    @Test("OC-0003 no public function is declared throws and every public Result carries FlotsamError")
    func publicSurfaceHasNoThrowsAndOnlyFlotsamResults() throws {
        let functions = try PublicAPI.shipped()
        #expect(functions.count > 40, "precondition: the scan found the module surface (\(functions.count) public functions)")
        #expect(PublicAPI.throwing(functions) == [], "public functions declared throws")
        #expect(PublicAPI.wrongResultError(functions) == [], "public functions returning a Result without FlotsamError")
    }
}

// MARK: - OC-0073 compile half

@Suite struct LogContextCompileTests {
    /// Directory holding `FlotsamBase.swiftmodule` from the package's own debug build.
    private static func moduleDirectory() throws -> String {
        let build = Repo.packageRoot().appendingPathComponent(".build/debug")
        for candidate in [build.appendingPathComponent("Modules"), build] {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("FlotsamBase.swiftmodule").path) { return candidate.path }
        }
        throw CompileSetupError.moduleNotBuilt(build.path)
    }

    private enum CompileSetupError: Error { case moduleNotBuilt(String) }

    /// Type-checks a snippet that imports FlotsamBase from outside the module (public API only).
    private static func typecheck(_ body: String) async throws -> ProcessResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Snippet.swift")
        try ("import FlotsamBase\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
        return try await runProcess("/usr/bin/xcrun", ["swiftc", "-typecheck", "-swift-version", "6", "-I", try moduleDirectory(), file.path])
    }

    /// OC-0073 control. Given a log context built from a validated BundleIdentifier and a PasteboardTypeID, when the
    /// snippet is type-checked, then it compiles. Without a green control a red result could mean a broken harness.
    @Test("OC-0073 control: validated bundle identifier and classified type identifier compile")
    func validContextCompiles() async throws {
        let result = try await Self.typecheck("""
        func good() -> [LogKey: LogSafeValue] {
            [.bundleId: .bundleId(BundleIdentifier("com.apple.TextEdit")!), .uti: .uti(PasteboardTypeID("public.png"))]
        }
        """)
        #expect(result.status == 0, "control must compile; output: \(result.output)")
    }

    static let mutations: [(name: String, snippet: String, mentions: String)] = [
        ("source-app bundle identifier given an arbitrary String literal",
         "func bad() -> [LogKey: LogSafeValue] { [.bundleId: .bundleId(\"the clip text\")] }", "BundleIdentifier"),
        ("source-app bundle identifier given a String variable",
         "func bad(_ clip: String) -> [LogKey: LogSafeValue] { [.bundleId: .bundleId(clip)] }", "BundleIdentifier"),
        ("pasteboard type identifier given an arbitrary String literal",
         "func bad() -> [LogKey: LogSafeValue] { [.uti: .uti(\"the clip text\")] }", "PasteboardTypeID"),
        ("pasteboard type identifier given a String variable",
         "func bad(_ clip: String) -> [LogKey: LogSafeValue] { [.uti: .uti(clip)] }", "PasteboardTypeID"),
    ]

    /// OC-0073. Given a log context whose bundle identifier or pasteboard type is given an arbitrary String, when the
    /// snippet is type-checked, then it fails to compile with a type error naming the validated type.
    @Test("OC-0073 an arbitrary String in a log context does not compile", arguments: mutations)
    func arbitraryStringDoesNotCompile(mutation: (name: String, snippet: String, mentions: String)) async throws {
        let result = try await Self.typecheck(mutation.snippet)
        #expect(result.status != 0, "\(mutation.name) must be rejected by the compiler")
        #expect(result.output.contains("error:"), "compiler error; output: \(result.output)")
        #expect(result.output.contains(mutation.mentions), "error names \(mutation.mentions); output: \(result.output)")
    }
}
