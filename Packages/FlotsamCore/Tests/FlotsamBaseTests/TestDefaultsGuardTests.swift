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

@Suite("TASK-520: test defaults suites are always cleaned up")
struct TestDefaultsGuardTests {
    // Red if any test file makes or removes a named suite itself: that call site has no plist cleanup.
    @Test("no test source creates a named suite or removes a domain itself: TestDefaultsSuite is the only home")
    func onlyTheHelperTouchesSuites() throws {
        let root = try #require(testsRoot(), "could not find the Tests directory")
        // Built from pieces so this file does not contain the strings it hunts for.
        let banned = ["UserDefaults(" + "suiteName", "removePersistent" + "Domain"]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var scanned = 0
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "TestDefaultsSuite.swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for needle in banned {
                #expect(!text.contains(needle), "\(url.lastPathComponent) uses \(needle) directly: use withTestDefaults or TestDefaultsSuite")
            }
        }
        #expect(scanned > 50, "the scan found only \(scanned) test files, so the guard is not looking at the tests")
    }

    // Red if remove() empties the domain but leaves the plist, which is the leak.
    @Test("remove() deletes the suite's plist as well as its values")
    func removeDeletesThePlist() throws {
        let suite = TestDefaultsSuite("task520.remove")
        suite.defaults.set("x", forKey: "k")
        #expect(waitForFile(suite.plistURL, seconds: 3), "precondition: writing a value creates the plist")
        suite.remove()
        #expect(!FileManager.default.fileExists(atPath: suite.plistURL.path))
        Thread.sleep(forTimeInterval: 1.5)  // past cfprefsd's late-write window
        #expect(!FileManager.default.fileExists(atPath: suite.plistURL.path), "the plist came back after remove()")
        #expect(suite.defaults.string(forKey: "k") == nil)
        suite.remove()  // idempotent
        #expect(!FileManager.default.fileExists(atPath: suite.plistURL.path))
    }

    // Red if withTestDefaults skips cleanup when the body throws.
    @Test("withTestDefaults cleans up when the body throws")
    func cleansUpOnThrow() throws {
        struct Boom: Error {}
        var url: URL?
        #expect(throws: Boom.self) {
            try withTestDefaults("task520.throw") { suite in
                url = suite.plistURL
                suite.defaults.set("x", forKey: "k")
                _ = waitForFile(suite.plistURL, seconds: 3)
                throw Boom()
            }
        }
        let gone = try #require(url)
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    // Red if deinit stops removing, so a test that forgets to call remove() leaks again.
    @Test("a suite that is dropped without remove() is still cleaned up")
    func deinitCleansUp() {
        var url: URL?
        do {
            let suite = TestDefaultsSuite("task520.deinit")
            url = suite.plistURL
            suite.defaults.set("x", forKey: "k")
            _ = waitForFile(suite.plistURL, seconds: 3)
        }
        #expect(url.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test("suite names are unique and carry the test prefix")
    func namesAreUniqueAndPrefixed() {
        let a = TestDefaultsSuite("task520.names"), b = TestDefaultsSuite("task520.names")
        #expect(a.name != b.name)
        #expect(a.name.hasPrefix(TestDefaultsSuite.namePrefix))
    }
}
