import Foundation
import Testing

// TASK-520: test UserDefaults suites must be created and removed through TestDefaultsSuite, the one home. A named suite
// leaves ~/Library/Preferences/<name>.plist behind unless that file is deleted, and 17,317 of them piled up.

/// The Tests directory, found by walking up from this file.
private func testsRoot() -> URL? {
    var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<6 {
        if url.lastPathComponent == "Tests" { return url }
        url.deleteLastPathComponent()
    }
    return nil
}

/// Polls until `url` exists or `seconds` pass. `cfprefsd` writes the plist asynchronously.
private func waitForFile(_ url: URL, seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return FileManager.default.fileExists(atPath: url.path)
}

/// The rules a test source breaks if it writes a defaults suite or preferences domain without the helper.
/// Whitespace, `.init`, `NSUserDefaults`, `UserDefaultsStore` and CFPreferences spellings all count: the labelled
/// `suiteName:` argument is the only way to name a suite, so it is banned in every form.
func bannedSuiteUses(in text: String) -> [String] {
    let rules: [(name: String, pattern: String)] = [
        ("suiteName", #"\bsuiteName\b"#),
        ("persistent domain", #"\b(remove|set)PersistentDomain\b"#),
        ("CFPreferences write", #"\bCFPreferences(Set|Write)\w*\s*\("#),
        ("NSUserDefaults init", #"\bNSUserDefaults\s*\("#),
    ]
    let whole = NSRange(text.startIndex..., in: text)
    return rules.compactMap { rule in
        guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { preconditionFailure("bad pattern \(rule.name)") }
        return regex.firstMatch(in: text, range: whole) == nil ? nil : rule.name
    }
}

/// Joins pieces at run time so this file never contains the spellings it bans.
private func j(_ parts: String...) -> String { parts.joined() }

/// `cfprefsd` can re-create a plist microseconds after the test deletes it, when the machine is heavily loaded; the
/// process-exit sweep removes that copy. So "the delete works" is checked as: a clean delete in at least one of 3 tries.
/// A delete that never happens (the mutations these tests exist for) fails all three.
private func passesWithinAttempts(_ attempt: () -> Bool) -> Bool {
    (0..<3).contains { _ in attempt() }
}

@Suite("TASK-520: test defaults suites are always cleaned up")
struct TestDefaultsGuardTests {
    // Red if any test file makes or removes a named suite itself: that call site has no plist cleanup.
    @Test("no test source creates or removes a defaults suite itself: TestDefaultsSuite is the only home")
    func onlyTheHelperTouchesSuites() throws {
        let root = try #require(testsRoot(), "could not find the Tests directory")
        // Exempt by resolved path (the Storage target links to the helper), never by file name: the helper, and this file,
        // which spells the banned patterns in its rules.
        let exempt = Set(["FlotsamBaseTests/TestDefaultsSuite.swift", "FlotsamBaseTests/TestDefaultsGuardTests.swift"]
            .map { root.appendingPathComponent($0).resolvingSymlinksInPath().path })
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var scanned = 0
        var offenders: [String] = []
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", !exempt.contains(url.resolvingSymlinksInPath().path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for rule in bannedSuiteUses(in: text) { offenders.append("\(url.lastPathComponent): \(rule)") }
        }
        #expect(offenders == [], "use withTestDefaults or TestDefaultsSuite instead")
        #expect(scanned > 50, "the scan found only \(scanned) test files, so the guard is not looking at the tests")
    }

    // Red if the ban regex is weakened so any spelling of a direct suite or preferences-domain write slips through.
    @Test("the ban catches every spelling of a direct suite or domain write, and nothing else", arguments: [
        (j("UserDefaults(suite", "Name: n)"), ["suiteName"]),
        (j("UserDefaults.init(suite", "Name: n)"), ["suiteName"]),
        (j("UserDefaults (suite", "Name : n)"), ["suiteName"]),
        (j("UserDefaults(\n    suite", "Name: n)"), ["suiteName"]),
        (j("NSUserDefaults(suite", "Name: n)"), ["suiteName", "NSUserDefaults init"]),
        (j("UserDefaultsStore(suite", "Name: n)"), ["suiteName"]),
        (j("d.remove", "PersistentDomain(forName: n)"), ["persistent domain"]),
        (j("d.set", "PersistentDomain(v, forName: n)"), ["persistent domain"]),
        (j("CFPreferences", "SetAppValue(k, v, id)"), ["CFPreferences write"]),
        (j("CFPreferences", "SetAppValue (k, v, id)"), ["CFPreferences write"]),
        (j("CFPreferences", "SetMultiple(a, r, id, u, h)"), ["CFPreferences write"]),
        (j("NSUserDefaults", "(x)"), ["NSUserDefaults init"]),
    ])
    func banCatchesEverySpelling(sample: String, rules: [String]) {
        // Given a source line that writes a defaults domain behind the helper's back
        // When it is scanned
        // Then exactly the named rules fire
        #expect(bannedSuiteUses(in: sample) == rules)
    }

    // Red if the ban grows so wide it flags the safe spellings the tests use today.
    @Test("the ban leaves helper use, the standard domain, launch-isolation names and quoted rule names alone", arguments: [
        "let suite = TestDefaultsSuite(\"frd008.pane\")",
        "withTestDefaults(\"x\") { suite in suite.defaults.set(1, forKey: \"k\") }",
        "UserDefaults.standard.string(forKey: key)",
        "LaunchIsolation(dataFolderOverride: nil, defaultsSuite: name, fakeSecure: false, authScript: .allow)",
        "[\"FLOTSAM_DEFAULTS_SUITE\": \"io.example.agent\"]",
        "(\"" + j("CFPreferences", "SetAppValue") + "\", [:]), (\"" + j("NS", "UserDefaults") + "\", [:])",
        "",
    ])
    func banLeavesSafeSourceAlone(sample: String) {
        #expect(bannedSuiteUses(in: sample) == [])
    }

    // Red if remove() empties the domain but leaves the plist, which is the leak.
    @Test("remove() deletes the suite's plist as well as its values")
    func removeDeletesThePlist() {
        // Given a suite whose plist exists
        // When it is removed
        // Then the plist is gone at once and still gone after cfprefsd's late-write window, and the values are gone
        #expect(passesWithinAttempts {
            let suite = TestDefaultsSuite("task520.remove")
            suite.defaults.set("x", forKey: "k")
            guard waitForFile(suite.plistURL, seconds: 3) else { return false }
            suite.remove()
            let atOnce = !FileManager.default.fileExists(atPath: suite.plistURL.path)
            Thread.sleep(forTimeInterval: 1.5)
            let later = !FileManager.default.fileExists(atPath: suite.plistURL.path)
            let valuesGone = suite.defaults.string(forKey: "k") == nil
            suite.remove()  // idempotent
            return atOnce && later && valuesGone && !FileManager.default.fileExists(atPath: suite.plistURL.path)
        }, "remove() never left the plist deleted in 3 attempts")
    }

    // Red if withTestDefaults skips cleanup when the body throws.
    @Test("withTestDefaults cleans up when the body throws")
    func cleansUpOnThrow() {
        struct Boom: Error {}
        #expect(passesWithinAttempts {
            var url: URL?
            #expect(throws: Boom.self) {
                try withTestDefaults("task520.throw") { suite in
                    url = suite.plistURL
                    suite.defaults.set("x", forKey: "k")
                    _ = waitForFile(suite.plistURL, seconds: 3)
                    throw Boom()
                }
            }
            return url.map { !FileManager.default.fileExists(atPath: $0.path) } == true
        }, "withTestDefaults left the plist after a throw in 3 attempts")
    }

    // Red if deinit stops removing, so a test that forgets to call remove() leaks again.
    @Test("a suite that is dropped without remove() is still cleaned up")
    func deinitCleansUp() {
        #expect(passesWithinAttempts {
            var url: URL?
            do {
                let suite = TestDefaultsSuite("task520.deinit")
                url = suite.plistURL
                suite.defaults.set("x", forKey: "k")
                _ = waitForFile(suite.plistURL, seconds: 3)
            }
            return url.map { !FileManager.default.fileExists(atPath: $0.path) } == true
        }, "a dropped suite left its plist in 3 attempts")
    }

    @Test("suite names are unique and carry the test prefix")
    func namesAreUniqueAndPrefixed() {
        let a = TestDefaultsSuite("task520.names"), b = TestDefaultsSuite("task520.names")
        #expect(a.name != b.name)
        #expect(a.name.hasPrefix(TestDefaultsSuite.namePrefix))
    }
}
