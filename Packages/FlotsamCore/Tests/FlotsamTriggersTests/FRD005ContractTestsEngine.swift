import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation
import Testing
@testable import FlotsamTriggers

// FRD-005 8T contract tests, slice S6 (trigger engine: FR-005-10, FR-005-19, FR-005-20, FR-005-21, BR-6;
// OC-5062, 5064, 5065, 5067, 5068, 5069, 5121, 5122, 5123, 5124, 5127, 5128, 5129, 5130, 5143), written from the
// blind oracle contract (.claude/oracle/frd-005-contract.json). Expected values are literals.
//
// Seams, all test doubles on production ports: `FakeKeyEventSource` is the event tap (`isInstalled` / `startCount` /
// `stopCount` answer "does the Flotsam process have an event tap"), `FakePermissions.requested` records every
// permission prompt, `RecordingPresenter` is the HUD and Notice surface, `ExpansionPasteboard.writes` is the clipboard,
// and `ExpansionStore.recorded` is the paste count. "The document contains exactly the typed characters" is the tap's
// decision for each key: `.pass` means the key reached the application untouched.
//
// Not observable at package level: the `trigger.expand` signpost interval and signposts in general (`Signposts` wraps
// `OSSignposter` with no recorder port, so OC-5127's signpost search and OC-5130's signpost reading cannot be done;
// the timing in OC-5130 is read at the same two points, expander entry and the paste post, instead).
// Analogues that stay as they are: TriggerEngineTests, TriggerPrivacyTests, TriggerPerformanceTests.

private let trigger = ";sig"
private let marker = "hunter2zqxmarker"
private let messageSETPRM002 = "Input Monitoring is off, so typed triggers are paused. Turn it on in System Settings › Privacy & Security."
private let messageTRGOS003 = "Typed triggers were paused by macOS and have been restarted."

/// Types `text`, then Space, as the tap sees it; returns the decision for every key down, Space last.
@MainActor
private func typeAndSpace(_ h: EngineHarness, _ text: String = trigger) -> [KeyDecision] {
    h.source.type(text) + [h.source.press(TriggerKeys.space, " ")]
}

private let allPass = [KeyDecision](repeating: .pass, count: 5)

/// Nothing happened to the user's world: no paste, no clipboard write, no HUD, nothing counted.
@MainActor
private func expectNoExpansion(_ h: EngineHarness, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(h.base.store.recorded.isEmpty, sourceLocation: sourceLocation)
    #expect(h.base.pasteboard.writes.isEmpty, sourceLocation: sourceLocation)
    #expect(h.base.presenter.huds.isEmpty, sourceLocation: sourceLocation)
    #expect(h.base.keys.actions.isEmpty, sourceLocation: sourceLocation)
}

/// An engine whose own log goes to the recording sink, over any binding source (the shared harness uses the OS log).
@MainActor
private func makeEngine(
    base: ExpanderHarness, source: FakeKeyEventSource, bindings: any ItemBindingSource, settings: SettingsStore,
    bus: ItemEventBus
) -> TriggerEngine {
    TriggerEngine(
        source: source, snapshot: base.snapshot, bindings: bindings, settings: settings, bus: bus,
        expander: base.expander, keyboard: base.environment, permissions: base.permissions, reporter: base.reporter,
        clock: GatedClock(), resetSignal: TriggerResetSignal(), ownBundleId: "com.example.flotsam", pollTick: PollTick(),
        sink: base.sink)
}

private struct NoDiagnosticsFacts: DiagnosticsDataSource {
    func permissionStates() async -> [PermissionName: PermissionState] { [:] }
    func itemCounts() async -> [ItemKind: Int] { [:] }
    func storageBytes() async -> (database: Int, blobs: Int) { (0, 0) }
}

@MainActor
@Suite("FRD-005 contract: trigger engine (S6)", .serialized, .timeLimit(.minutes(2)))
struct FRD005ContractTestsEngine {
    private let itemId = ExpanderHarness.itemId

    private func harness(
        triggers: [UUID: String]? = nil, triggersEnabled: Bool = true, base: ExpanderHarness = ExpanderHarness()
    ) -> EngineHarness {
        EngineHarness(triggers: triggers ?? [itemId: trigger], triggersEnabled: triggersEnabled, base: base)
    }

    // MARK: Tap exists only when it must (FR-005-10)

    @Test("OC-5062 with no trigger and both permissions granted there is no tap and no permission prompt")
    func oc5062NoTriggerNoTap() async {
        // given no item has a trigger, Accessibility and Input Monitoring granted, triggers.enabled on
        let h = harness(triggers: [:])
        // when the engine starts and the watchdog runs (event taps of the process are listed)
        await h.engine.start()
        defer { h.engine.stop() }
        await h.engine.watchdogTick()
        // then there are none, and no permission prompt was requested
        #expect(h.engine.status == .idle)
        #expect(h.source.startCount == 0)
        #expect(!h.source.isInstalled)
        #expect(h.base.permissions.requested.isEmpty)

        // control: the same state with one trigger does create exactly one tap
        let withTrigger = harness()
        await withTrigger.engine.start()
        defer { withTrigger.engine.stop() }
        #expect(withTrigger.source.startCount == 1)
        #expect(withTrigger.source.isInstalled)
    }

    @Test("OC-5064 Input Monitoring off: no tap, ';sig' + Space reaches the app untouched, SET-PRM-002 is reported")
    func oc5064InputMonitoringOff() async {
        // given an item with ';sig', Accessibility granted, Input Monitoring not granted
        let h = harness()
        h.base.permissions.set(.inputMonitoring, granted: false)
        // when the user types ';sig' Space and Settings > Triggers asks for the state
        await h.engine.start()
        defer { h.engine.stop() }
        let decisions = typeAndSpace(h)
        // then no tap exists
        #expect(h.source.startCount == 0)
        #expect(!h.source.isInstalled)
        #expect(h.engine.status == .inert([.setPrm002]))
        // and every key including the boundary key went through: the document holds exactly what was typed
        #expect(decisions == allPass)
        // and the clipboard, HUD and paste count are untouched
        expectNoExpansion(h)
        // and SET-PRM-002 is reported with its catalogue text
        #expect(await eventually { h.noticeCodes == [.setPrm002] })
        #expect(h.base.presenter.notices.map(\.message) == [messageSETPRM002])
        #expect(h.base.permissions.requested.isEmpty)
    }

    @Test("OC-5065 granting Input Monitoring creates the tap on the next watchdog pass (<= 5 s) and ';sig' expands")
    func oc5065GrantingInstallsTap() async {
        // given the OC-5064 state
        let h = harness()
        h.base.permissions.set(.inputMonitoring, granted: false)
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.source.startCount == 0)
        // when the user grants Input Monitoring and the watchdog period (5 s) passes
        #expect(TriggerKeys.watchdogInterval <= 5)
        h.base.permissions.set(.inputMonitoring, granted: true)
        h.runWatchdogPass()
        // then a tap exists
        #expect(await eventually { h.engine.status == .running })
        #expect(h.source.startCount == 1)
        #expect(h.source.isInstalled)
        // and ';sig' expands: Space is consumed, the item is pasted once
        #expect(typeAndSpace(h) == [.pass, .pass, .pass, .pass, .consume])
        #expect(await eventually { h.base.store.recorded == [itemId] })
    }

    @Test("OC-5067 turning 'Expand typed triggers' off removes the tap and ';sig' + Space reaches the app untouched")
    func oc5067SettingOff() async {
        // given an item with ';sig' and permissions granted (the tap exists)
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.source.isInstalled)
        // when the user turns 'Expand typed triggers' off and types ';sig' Space
        h.settings.set(false, for: SettingKeys.triggersEnabled)
        #expect(await eventually { h.engine.status == .off })
        let decisions = typeAndSpace(h)
        // then no tap exists, the typed characters all went through, nothing was pasted, written or shown
        #expect(!h.source.isInstalled)
        #expect(h.source.stopCount == 1)
        #expect(decisions == allPass)
        expectNoExpansion(h)

        // control: turning it back on creates the tap again and the same typing expands
        h.settings.set(true, for: SettingKeys.triggersEnabled)
        #expect(await eventually { h.engine.status == .running })
        #expect(typeAndSpace(h).last == .consume)
        #expect(await eventually { h.base.store.recorded == [itemId] })
    }

    @Test("OC-5068 the Input Monitoring prompt appears when the first trigger is saved, not earlier")
    func oc5068PromptAtFirstTrigger() async {
        // given no triggers exist and Input Monitoring was never requested
        let h = harness(triggers: [:])
        h.base.permissions.set(.inputMonitoring, granted: false)
        await h.engine.start()
        defer { h.engine.stop() }
        await h.engine.watchdogTick()
        // then nothing was requested at launch or on a watchdog pass
        #expect(h.base.permissions.requested.isEmpty)
        // when the user saves the first trigger on an item
        h.bindings.setTriggers([itemId: trigger])
        await h.engine.userDidSaveTrigger()
        // then the request appears at that moment, once, for Input Monitoring only
        #expect(h.base.permissions.requested == [.inputMonitoring])

        // negative: with everything already granted, saving a trigger prompts for nothing
        let granted = harness(triggers: [:])
        await granted.engine.start()
        defer { granted.engine.stop() }
        granted.bindings.setTriggers([itemId: trigger])
        await granted.engine.userDidSaveTrigger()
        #expect(granted.base.permissions.requested.isEmpty)
        #expect(granted.engine.status == .running)
    }

    @Test("OC-5069 deleting the only item's trigger removes the tap")
    func oc5069LastTriggerRemoved() async {
        // given exactly one item has a trigger and a tap exists
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.source.isInstalled)
        #expect(h.source.stopCount == 0)
        // when the user deletes that trigger (the editor writes the binding, the bus announces the change)
        h.bindings.setTriggers([:])
        h.bus.publish(.itemsChanged)
        // then the process has no tap, removed exactly once, and nothing was prompted
        #expect(await eventually { h.engine.status == .idle })
        #expect(!h.source.isInstalled)
        #expect(h.source.stopCount == 1)
        #expect(h.base.permissions.requested.isEmpty)
    }

    @Test("OC-5143 deleting the only trigger item removes the tap with no prompt; deleting another item keeps it")
    func oc5143DeleteItem() async {
        // given exactly one item has a trigger and a tap exists
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.source.isInstalled)
        // when the user deletes that item
        h.bindings.setTriggers([:])
        h.bus.publish(.itemsDeleted([itemId]))
        // then the process has no tap and no permission prompt appeared
        #expect(await eventually { h.engine.status == .idle })
        #expect(!h.source.isInstalled)
        #expect(h.source.stopCount == 1)
        #expect(h.base.permissions.requested.isEmpty)
        #expect(h.base.presenter.huds.isEmpty)

        // negative: with two trigger items, deleting one leaves the tap, and only the survivor expands
        let survivor = UUID()
        let two = harness(triggers: [itemId: trigger, survivor: ";other"])
        await two.engine.start()
        defer { two.engine.stop() }
        two.bindings.setTriggers([survivor: ";other"])
        two.bus.publish(.itemsDeleted([itemId]))
        await two.engine.watchdogTick()
        #expect(two.source.isInstalled)
        #expect(two.source.stopCount == 0)
        #expect(typeAndSpace(two, trigger).last == .pass)
        #expect(typeAndSpace(two, ";other").last == .consume)
        #expect(await eventually { two.base.store.recorded == [survivor] })
    }

    // MARK: Tap health (FR-005-19)

    @Test("OC-5121 a tap disabled by timeout is restarted, ';sig' expands, and the TRG-OS-003 Notice appears")
    func oc5121TimeoutRestart() async {
        // given trigger ';sig' and tapDisabledByTimeout simulated
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        // when the event arrives and the user types ';sig' Space
        h.source.simulateDisable(.timeout)
        let decisions = typeAndSpace(h)
        // then the expansion works
        #expect(h.source.reenableCount == 1)
        #expect(h.source.isHealthy)
        #expect(decisions == [.pass, .pass, .pass, .pass, .consume])
        #expect(await eventually { h.base.store.recorded == [itemId] })
        // and the Notice with the catalogue text appears, once
        #expect(await eventually { h.noticeCodes == [.trgOs003] })
        #expect(h.base.presenter.notices.map(\.message) == [messageTRGOS003])
    }

    @Test("OC-5122 three disablements within 60 s latch the tap off with the dot held until the setting is toggled")
    func oc5122ThreeDisablementsLatch() async {
        // given trigger ';sig' and three disablements within 60 s (t = 0, 30, 59)
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        h.source.simulateDisable()
        h.clock.advance(30)
        h.source.simulateDisable()
        h.clock.advance(29)
        h.source.simulateDisable()
        // when the user types ';sig' Space
        #expect(await eventually { h.engine.status == .latchedOff })
        let first = typeAndSpace(h)
        // then the first attempt does not expand and the warning dot stays
        #expect(first == allPass)
        expectNoExpansion(h)
        #expect(h.engine.showsWarningDot)
        #expect(!h.source.isInstalled)
        h.runWatchdogPass()
        await h.engine.watchdogTick()
        #expect(h.engine.showsWarningDot)
        #expect(h.source.startCount == 1)
        // when the user toggles 'Expand typed triggers' off and on
        h.settings.set(false, for: SettingKeys.triggersEnabled)
        #expect(await eventually { h.engine.status == .off })
        #expect(!h.engine.showsWarningDot)
        h.settings.set(true, for: SettingKeys.triggersEnabled)
        #expect(await eventually { h.engine.status == .running })
        // then it expands
        #expect(typeAndSpace(h).last == .consume)
        #expect(await eventually { h.base.store.recorded == [itemId] })
    }

    @Test("OC-5122 three disablements spread over more than 60 s (t = 0, 31, 62) do not latch")
    func oc5122SpreadDisablementsDoNotLatch() async {
        // given trigger ';sig' and three disablements, the third 62 s after the first
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        // when they happen
        h.source.simulateDisable()
        h.clock.advance(31)
        h.source.simulateDisable()
        h.clock.advance(31)
        h.source.simulateDisable()
        // then every one was re-enabled, nothing latched, no dot, and the trigger still expands
        #expect(h.source.reenableCount == 3)
        #expect(!h.engine.showsWarningDot)
        #expect(h.source.isHealthy)
        #expect(typeAndSpace(h).last == .consume)
        #expect(await eventually { h.base.store.recorded == [itemId] })
    }

    @Test("OC-5123 a tap disabled with no callback is re-enabled by the 5 s watchdog and ';sig' expands")
    func oc5123WatchdogReenables() async {
        // given the tap is disabled without a callback
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        h.source.disableSilently()
        #expect(!h.source.isHealthy)
        #expect(h.source.reenableCount == 0)
        // when 5 s pass (one watchdog period) and the user types ';sig' Space
        #expect(TriggerKeys.watchdogInterval <= 5)
        h.runWatchdogPass()
        #expect(await eventually { h.source.isHealthy })
        let decisions = typeAndSpace(h)
        // then the watchdog re-enabled the tap exactly once and the trigger expands
        #expect(h.source.reenableCount == 1)
        #expect(decisions == [.pass, .pass, .pass, .pass, .consume])
        #expect(await eventually { h.base.store.recorded == [itemId] })
    }

    @Test("OC-5124 revoking Input Monitoring removes the tap within a watchdog period, no expansion, SET-PRM-002 reported")
    func oc5124RevokedWhileRunning() async {
        // given the trigger tap is active
        let h = harness()
        await h.engine.start()
        defer { h.engine.stop() }
        #expect(h.source.isInstalled)
        // when the user revokes Input Monitoring, 5 s pass and the user types ';sig' Space
        h.base.permissions.set(.inputMonitoring, granted: false)
        h.runWatchdogPass()
        #expect(await eventually { h.engine.status == .inert([.setPrm002]) })
        let decisions = typeAndSpace(h)
        // then no tap exists, nothing expanded, and SET-PRM-002 is reported with its text
        #expect(!h.source.isInstalled)
        #expect(h.source.stopCount == 1)
        #expect(decisions == allPass)
        expectNoExpansion(h)
        #expect(await eventually { h.noticeCodes == [.setPrm002] })
        #expect(h.base.presenter.notices.map(\.message) == [messageSETPRM002])
    }

    // MARK: Privacy (FR-005-20)

    @Test("OC-5127 a typed marker word, ';sig' and typed text appear in no log, Notice, HUD, error history or diagnostics report")
    func oc5127NoTypedTextInLogsOrReport() async {
        // given a debug run with trigger ';sig' (the engine's own log goes to the recording sink)
        let base = ExpanderHarness()
        let source = FakeKeyEventSource()
        let settings = SettingsStore(store: InMemoryKeyValueStore())
        settings.set(true, for: SettingKeys.triggersEnabled)
        let engine = makeEngine(
            base: base, source: source, bindings: FakeItemBindingSource(triggers: [ExpanderHarness.itemId: trigger]),
            settings: settings, bus: ItemEventBus())
        await engine.start()
        defer { engine.stop() }
        // when the user types a marker word, Space, then ';sig' Space, once expanded and once in secure input
        source.type(marker)
        #expect(source.press(TriggerKeys.space, " ") == .pass)
        source.type(trigger)
        #expect(source.press(TriggerKeys.space, " ") == .consume)
        #expect(await eventually { base.store.recorded == [ExpanderHarness.itemId] })
        base.environment.secureInput = true
        source.type(trigger)
        #expect(source.press(TriggerKeys.space, " ") == .pass)
        #expect(await eventually { base.sink.allText.contains("TRG-POL-001") })
        // and a macOS tap pause, a Warning, so the error history and the report carry an outcome code too
        base.environment.secureInput = false
        source.simulateDisable(.timeout)
        #expect(await eventually { !base.presenter.notices.isEmpty })
        // then the log, Notices, HUDs, error history and the rendered diagnostics report hold none of it
        let history = await base.reporter.recentErrors()
        let snapshot = await DiagnosticsSnapshotBuilder(
            settings: settings, source: NoDiagnosticsFacts(), recentErrors: { history }).build()
        let report = DiagnosticsReport.render(snapshot)
        let surfaces: [String] = [
            base.sink.allText,
            (base.presenter.huds + base.presenter.notices.map { String(describing: $0) }).joined(separator: "\n"),
            history.map { String(describing: $0) }.joined(separator: "\n"),
            report,
        ]
        // the scan is not vacuous: outcome codes are present where they should be
        #expect(history.map(\.code) == [.trgOs003])
        #expect(report.contains("TRG-OS-003"))
        for text in surfaces {
            for typed in [marker, trigger, "hunter2", "zqxmarker"] {
                #expect(!text.localizedCaseInsensitiveContains(typed), "found \"\(typed)\"")
            }
        }
    }

    @Test("OC-5128 after a real-database expansion run the data folder holds no copy of the typed marker word")
    func oc5128NoTypedTextOnDisk() async throws {
        // given the same run over the real database and a real data folder (the item's own text is stored there)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flotsam-8t-frd005-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await FlotsamDatabase.open(folder: folder).get()
        let ingest = IngestActor(database: db, settings: SettingsStore(store: InMemoryKeyValueStore()))
        let body = "itembodyzqxunique"
        let created = try await ingest.ingest(
            IngestCandidate(
                kind: .text, contentKey: "text:\(body)", plainText: body, origin: .pasteboard,
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000))).get()
        guard case .created(let realItem) = created.outcome else {
            Issue.record("item was not created")
            return
        }
        #expect(try await db.applyExemptionEdit(.setTrigger(trigger), to: realItem).get())

        let base = ExpanderHarness()
        let ledger = OwnWriteLedger()
        let preserver = ClipboardPreserver(pasteboard: base.pasteboard, ownWrites: ledger, clock: base.clock)
        let paste = PasteService(
            store: db, pasteboard: base.pasteboard, files: NoFiles(),
            frontmost: EnvironmentFrontmost(environment: base.environment), accessibility: base.permissions,
            keys: base.keys, clock: base.clock, ownWrites: ledger)
        let expander = TriggerExpander(
            store: db, pasteboard: base.pasteboard, files: NoFiles(), codec: NoRichText(), preserver: preserver,
            ownWrites: ledger, paste: paste, keys: base.keys, keyboard: base.environment, snapshot: base.snapshot,
            permissions: base.permissions, reporter: base.reporter, clock: base.clock, ownBundleId: "com.example.flotsam",
            calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"), sink: base.sink)
        let source = FakeKeyEventSource()
        let settings = SettingsStore(store: InMemoryKeyValueStore())
        settings.set(true, for: SettingKeys.triggersEnabled)
        let engine = TriggerEngine(
            source: source, snapshot: base.snapshot, bindings: db, settings: settings, bus: ItemEventBus(),
            expander: expander, keyboard: base.environment, permissions: base.permissions, reporter: base.reporter,
            clock: GatedClock(), resetSignal: TriggerResetSignal(), ownBundleId: "com.example.flotsam",
            pollTick: PollTick(), sink: base.sink)
        await engine.start()
        defer { engine.stop() }
        #expect(source.isInstalled)

        // when the user types the marker word, Space, then ';sig' Space
        source.type(marker)
        #expect(source.press(TriggerKeys.space, " ") == .pass)
        source.type(trigger)
        #expect(source.press(TriggerKeys.space, " ") == .consume)
        // (the expansion pastes the item's text: the run really went through the database)
        #expect(await eventually { base.pasteboard.writes.first?.compactMap { String(data: $0.data, encoding: .utf8) }.joined() == body })

        // then the data folder, database and journal files included, holds zero occurrences of the marker word
        func occurrences(of word: String) -> Int {
            let needle = Data(word.utf8)
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            return files.reduce(0) { count, url in
                guard let data = try? Data(contentsOf: url), data.range(of: needle) != nil else { return count }
                return count + 1
            }
        }
        // the scan is not vacuous: the item's own text, which is stored, is found
        #expect(occurrences(of: body) >= 1)
        #expect(occurrences(of: marker) == 0)
        #expect(occurrences(of: "hunter2") == 0)
    }

    // MARK: Performance (FR-005-21)

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Nearest-rank percentile.
    private func percentile(_ p: Double, of samples: [Double]) -> Double {
        let sorted = samples.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[max(0, min(sorted.count - 1, rank))]
    }

    @Test("OC-5129 with 100 triggers defined, 1,000 scripted key events cost the tap callback p99 <= 1 ms")
    func oc5129CallbackP99() {
        // given 100 triggers
        var triggers: [UUID: String] = [:]
        for index in 0..<100 { triggers[UUID()] = ";q\(String(format: "%03d", index))" }
        let texts = Array(triggers.values)
        #expect(texts.count == 100)
        let h = MatcherHarness(triggers: triggers)
        // when 1,000 scripted events are sent: matching words, non-trigger words and backspace-edited words
        var events: [KeyEvent] = []
        func key(_ code: UInt16, _ characters: String) {
            events.append(KeyEvent(kind: .keyDown, keyCode: code, characters: characters))
            events.append(KeyEvent(kind: .keyUp, keyCode: code, characters: characters))
        }
        var word = 0
        while events.count < 1_200 {
            let text = switch word % 3 {
            case 0: texts[(word / 3) % texts.count]
            case 1: "plainword\(word)"
            default: ";q0\(word % 10)x"
            }
            for ch in text { key(0, String(ch)) }
            if word % 3 == 2 { key(TriggerKeys.backspace, "") }
            key(TriggerKeys.space, " ")
            word += 1
        }
        for event in events.prefix(200) { _ = h.matcher.process(event) }  // warm-up
        let clock = ContinuousClock()
        var samples: [Double] = []
        var matches = 0
        for event in events.dropFirst(200).prefix(1_000) {
            var result = MatcherResult.pass
            samples.append(seconds(clock.measure { result = h.matcher.process(event) }))
            if case .matched = result { matches += 1 }
        }
        // then p99 of the callback time is at most 1 ms, and the script really matched triggers
        #expect(samples.count == 1_000)
        #expect(matches >= 15)
        let p99 = percentile(0.99, of: samples)
        #expect(p99 <= 0.001, "p99 \(p99 * 1000) ms")
    }

    @Test("OC-5130 boundary key to the paste post is p95 <= 150 ms over 50 expansions of a 10 KB item")
    func oc5130ExpansionP95() async {
        // given a 10 KB text item with a trigger
        let body = String(repeating: "0123456789abcdef", count: 640)
        #expect(body.utf8.count == 10_240)
        let h = ExpanderHarness(content: .success(ItemContent(kind: .text, plainText: body, representations: [], members: [])))
        let clock = ContinuousClock()
        var samples: [Double] = []
        var started = clock.now
        var nominalAtPaste = 0.0
        var pasted = false
        h.keys.onAction = {
            guard !pasted, h.keys.actions.last == .paste else { return }
            pasted = true
            samples.append(self.seconds(clock.now - started))
            nominalAtPaste = h.clock.slept.reduce(0) { $0 + self.seconds($1) }
        }
        // when 50 expansions are timed (compute time to the post plus the sleeps the sequence asked for before it)
        for _ in 0..<50 {
            pasted = false
            let nominalBefore = h.clock.slept.reduce(0) { $0 + self.seconds($1) }
            started = clock.now
            #expect(await h.expander.expand(h.match()) == .expanded)
            #expect(pasted)
            samples[samples.count - 1] += nominalAtPaste - nominalBefore
        }
        // then p95 is at most 150 ms, and each sample includes the real settle wait (not just compute)
        #expect(samples.count == 50)
        #expect(samples.allSatisfy { $0 >= 0.01 })
        let p95 = percentile(0.95, of: samples)
        #expect(p95 <= 0.150, "p95 \(p95 * 1000) ms")
    }
}
