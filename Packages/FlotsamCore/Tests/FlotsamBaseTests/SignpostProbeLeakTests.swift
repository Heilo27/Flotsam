import Foundation
import Testing

// TASK-481: a signpost test whose process died (timeout, crash, kill) left its `log stream` child running forever,
// reparented to launchd; three were found 5 to 29 hours old. SignpostProbe must end that child on every exit path.
// Each test names one path and fails if the child is still alive afterwards.

func isAlive(_ pid: Int32) -> Bool {
    // A reaped or reparented-and-exited process is gone; a zombie still answers signal 0, so ask `ps` for its state.
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-o", "stat=", "-p", String(pid)]
    let pipe = Pipe()
    ps.standardOutput = pipe
    ps.standardError = FileHandle.nullDevice
    guard (try? ps.run()) != nil else { return false }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    ps.waitUntilExit()
    let state = out.trimmingCharacters(in: .whitespacesAndNewlines)
    return !state.isEmpty && !state.hasPrefix("Z")
}

func waitUntilGone(_ pid: Int32, seconds: Double) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if !isAlive(pid) { return true }
        try await Task.sleep(for: .milliseconds(100))
    }
    return !isAlive(pid)
}

@Suite(.serialized, .timeLimit(.minutes(2))) struct SignpostProbeLeakTests {
    /// Starts a probe, returns the live child's pid after checking it really is running (so "gone" later means something).
    private func startedChild(_ probe: SignpostProbe) async throws -> Int32 {
        try await probe.start()
        let pid = try #require(probe.childPID, "the launcher never wrote the log stream pid")
        #expect(isAlive(pid), "precondition: the log stream child should be running after start()")
        return pid
    }

    @Test("OC-TASK481-01: stop() ends the log stream child")
    func stopEndsChild() async throws {
        let probe = SignpostProbe()
        let pid = try await startedChild(probe)
        await probe.stop()
        #expect(try await waitUntilGone(pid, seconds: 5), "log stream pid \(pid) survived stop()")
    }

    @Test("OC-TASK481-02: dropping a probe without stop() (a throw or early return) still ends the child")
    func droppedProbeEndsChild() async throws {
        var pid: Int32 = 0
        do {
            let probe = SignpostProbe()
            pid = try await startedChild(probe)
        }  // probe released here without stop(), as when a test throws before reaching its stop()
        let gone = try await waitUntilGone(pid, seconds: 5)
        if !gone { kill(pid, SIGKILL) }  // do not leave the leak this test just proved
        #expect(gone, "log stream pid \(pid) survived its probe being released")
    }

    @Test("OC-TASK481-03: the child ends when its parent process is killed (no Swift code runs on SIGKILL)")
    func childEndsWhenParentDies() async throws {
        let parent = Process()  // a stand-in for the test process: killing it is how a timed-out run dies
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["300"]
        try parent.run()
        defer { if parent.isRunning { kill(parent.processIdentifier, SIGKILL) } }

        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-leaktest-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let launcher = SignpostProbe.launch(parentPID: parent.processIdentifier, executable: "/bin/sleep", arguments: ["300"], pidFile: pidFile)
        try launcher.run()
        defer { if launcher.isRunning { launcher.terminate() } }

        var childPID: Int32?
        for _ in 0..<50 where childPID == nil {
            childPID = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if childPID == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let child = try #require(childPID, "the launcher never wrote the child pid")
        #expect(isAlive(child), "precondition: the child should be running while its parent is alive")

        kill(parent.processIdentifier, SIGKILL)
        let gone = try await waitUntilGone(child, seconds: 10)
        if !gone { kill(child, SIGKILL) }
        #expect(gone, "child pid \(child) outlived its killed parent")
    }
}

// TASK-481 (OC-WORF457-02): `start()` used to pause a fixed 800 ms after `log stream` printed "Filtering the log data", but
// the stream attaches to the live feed after that line and does not replay, so under host load a signpost emitted right
// after start() could be lost and a test saw no events at all. start() now returns only once the stream has handed back
// a beacon the probe itself emitted.
@Suite(.serialized, .timeLimit(.minutes(2))) struct SignpostProbeReadinessTests {
    @Test("OC-TASK481-04: start() returns only after the stream has delivered a beacon, and the beacon is never reported as an event")
    func startWaitsForAttachment() async throws {
        let probe = SignpostProbe()
        try await probe.start()
        #expect(probe.beaconSeen, "start() returned before the stream proved it was attached")
        #expect(probe.marks().allSatisfy { $0.event.category != SignpostProbe.beaconCategory }, "the readiness beacon leaked into the events")
        await probe.stop()
    }
}

// TASK-481 (Worf): paths the builder's three leak tests do not reach.
@Suite(.serialized, .timeLimit(.minutes(2))) struct Worf481ProbeLifecycleTests {
    /// OC-W481-03 (empty). A probe that was never started has no child, and stop() on it returns without crashing or
    /// hanging. Red if childPID reports a stale value before start, or stop() blocks waiting for a process that never ran.
    @Test("OC-W481-03 stop() on a probe that never started returns and reports no child")
    func stopWithoutStart() async {
        let probe = SignpostProbe()
        #expect(probe.childPID == nil)
        await probe.stop()
        await probe.stop()
        #expect(probe.childPID == nil)
        #expect(probe.marks().isEmpty)
    }

    /// OC-W481-04 (boundary). A launcher started when its parent is ALREADY dead still ends its child: the watcher must
    /// not rely on seeing the parent alive first. Red if the watcher is removed, or only starts after a first live check.
    @Test("OC-W481-04 a child launched for an already-exited parent is ended by the launcher within 5 s")
    func childEndsWhenParentAlreadyGone() async throws {
        // given a parent that has already exited
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try parent.run()
        parent.waitUntilExit()
        let deadPID = parent.processIdentifier

        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-w481-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        // when a launcher starts a long-lived child on its behalf
        let launcher = SignpostProbe.launch(parentPID: deadPID, executable: "/bin/sleep", arguments: ["300"], pidFile: pidFile)
        try launcher.run()
        defer { if launcher.isRunning { launcher.terminate() } }
        var childPID: Int32?
        for _ in 0..<50 where childPID == nil {
            childPID = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if childPID == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let child = try #require(childPID, "the launcher never wrote the child pid")

        // then the child is gone within 5 s (watcher polls once a second)
        let gone = try await waitUntilGone(child, seconds: 5)
        if !gone { kill(child, SIGKILL) }
        #expect(gone, "child pid \(child) outlived a parent that was already dead at launch")
    }

    /// OC-W481-05 (negative). While the parent is alive the launcher must NOT end the child on its own: a watcher that
    /// fires early would kill every probe mid-capture. Red if the child dies within 3 s with its parent still running.
    @Test("OC-W481-05 a child whose parent is alive survives past the watcher's poll interval")
    func childSurvivesWhileParentAlive() async throws {
        // given a live parent
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["60"]
        try parent.run()
        defer { if parent.isRunning { kill(parent.processIdentifier, SIGKILL) } }

        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-w481b-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let launcher = SignpostProbe.launch(parentPID: parent.processIdentifier, executable: "/bin/sleep", arguments: ["60"], pidFile: pidFile)
        try launcher.run()
        var childPID: Int32?
        for _ in 0..<50 where childPID == nil {
            childPID = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if childPID == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let child = try #require(childPID)

        // when more than two watcher polls pass
        try await Task.sleep(for: .seconds(3))

        // then the child is still running, and ending the launcher ends it
        #expect(isAlive(child), "the watcher killed a child whose parent was alive")
        launcher.terminate()
        let gone = try await waitUntilGone(child, seconds: 5)
        if !gone { kill(child, SIGKILL) }
        #expect(gone, "terminating the launcher left child \(child) running")
    }
}
