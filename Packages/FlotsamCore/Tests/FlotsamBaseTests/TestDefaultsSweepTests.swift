import Foundation
import Testing

// TASK-520: the process-exit sweep deletes the plists cfprefsd re-creates after a test's own delete. It must delete only
// the names this process made, wait for the late writes, and really run at process exit.

private let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")

private func makePlist(named name: String) throws -> URL {
    let url = preferences.appendingPathComponent("\(name).plist")
    try Data("x".utf8).write(to: url)
    return url
}

/// Set by the parent test; the child run below acts only when it is present.
private let childOutKey = "FLOTSAM_TASK520_CHILD_OUT"

/// Holds the suite so neither `remove()` nor `deinit` ever runs: only the exit sweep can delete its plist.
private enum Leaked { nonisolated(unsafe) static var held: [TestDefaultsSuite] = [] }

@Suite("TASK-520: process-exit sweep")
struct TestDefaultsSweepTests {
    // Red if the sweep deletes by glob or deletes names it was not told about.
    @Test("sweep() deletes the plists of tracked suites and leaves every other file alone")
    func deletesOnlyTrackedNames() throws {
        // Given two plists in the preferences folder, only one of them tracked
        let tracked = "flotsam.test.task520.sweep.\(UUID().uuidString)"
        let sibling = "flotsam.test.task520.sibling.\(UUID().uuidString)"
        let trackedURL = try makePlist(named: tracked)
        let siblingURL = try makePlist(named: sibling)
        defer { try? FileManager.default.removeItem(at: siblingURL); try? FileManager.default.removeItem(at: trackedURL) }
        let sweep = TestDefaultsExitSweep(settleSeconds: 0)
        sweep.track(tracked)
        // When it sweeps
        sweep.sweep()
        // Then the tracked plist is gone and the sibling survives
        #expect(!FileManager.default.fileExists(atPath: trackedURL.path))
        #expect(FileManager.default.fileExists(atPath: siblingURL.path))
    }

    // Red if a sweep with nothing tracked deletes anything.
    @Test("sweep() with nothing tracked deletes nothing")
    func emptySweepDeletesNothing() throws {
        let sibling = try makePlist(named: "flotsam.test.task520.empty.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sibling) }
        TestDefaultsExitSweep(settleSeconds: 0).sweep()
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }

    // Red if the settle wait is dropped: the delete would run before cfprefsd's late write and the file would return.
    @Test("sweep() waits out the settle window after the last activity before deleting")
    func waitsForTheSettleWindow() throws {
        let name = "flotsam.test.task520.settle.\(UUID().uuidString)"
        let url = try makePlist(named: name)
        defer { try? FileManager.default.removeItem(at: url) }
        let sweep = TestDefaultsExitSweep(settleSeconds: 0.6)
        sweep.track(name)
        let started = Date()
        sweep.sweep()
        #expect(Date().timeIntervalSince(started) >= 0.5)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // Red if the exit hook is not registered, or does not delete, in a real process: this runs a second copy of the test
    // process that leaks a suite on purpose and checks the file is gone after that process has exited.
    @Test("a suite nobody removes is deleted by the sweep when its process exits")
    func exitHookDeletesALeakedSuite() throws {
        // Given the arguments this test process was started with, pointed at the child test only
        let args = CommandLine.arguments
        let bundleFlag = try #require(args.firstIndex(of: "--test-bundle-path"), "not run by swiftpm-testing-helper")
        let bundle = args[bundleFlag + 1]
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("task520-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: args[0])
        child.arguments = ["--test-bundle-path", bundle, "--filter", "childLeaksOneSuiteOnPurpose", bundle, "--testing-library", "swift-testing"]
        child.environment = ProcessInfo.processInfo.environment.merging([childOutKey: out.path]) { _, new in new }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        // When the child runs to completion and exits
        try child.run()
        child.waitUntilExit()
        // Then it made a real suite plist, left it, and the exit sweep deleted it
        let plist = try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        defer { try? FileManager.default.removeItem(atPath: plist) }
        #expect(child.terminationStatus == 0, "the child run failed")
        #expect(plist.hasPrefix(preferences.path + "/" + TestDefaultsSuite.namePrefix), "the child did not report a test suite plist: \(plist)")
        #expect(!FileManager.default.fileExists(atPath: plist), "the exit sweep left \(plist) behind")
    }

    /// The child half of the test above. Does nothing in a normal run.
    @Test("child entry point for exitHookDeletesALeakedSuite: leaks one suite and never removes it")
    func childLeaksOneSuiteOnPurpose() throws {
        guard let out = ProcessInfo.processInfo.environment[childOutKey] else { return }
        let suite = TestDefaultsSuite("task520.child")
        Leaked.held.append(suite)
        suite.defaults.set("x", forKey: "k")
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: suite.plistURL.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(FileManager.default.fileExists(atPath: suite.plistURL.path), "precondition: the suite wrote its plist")
        try suite.plistURL.path.write(toFile: out, atomically: true, encoding: .utf8)
    }
}
