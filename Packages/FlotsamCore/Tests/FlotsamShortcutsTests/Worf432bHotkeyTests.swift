import Foundation
import Testing
import FlotsamBase
@testable import FlotsamShortcuts

// TASK-432 blind QA, FR-000-11 "hotkey registered": one line per OS registration attempt, with its outcome.

private final class HotkeySink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [LogRecord] = []
    var records: [LogRecord] { lock.withLock { all } }
    func write(_ record: LogRecord) { lock.withLock { all.append(record) } }
}

@MainActor
@Suite struct Worf432bHotkeyTests {
    /// OC-432-30. Given the OS accepts the chord, when bound, then one `hotkey.registered outcome=registered` at .info
    /// and nothing that names the chord. Red if the success callsite is dropped or logs failed.
    @Test func oc43230_successfulBindLogsRegistered() {
        let sink = HotkeySink()
        let registry = ShortcutRegistry(registrar: FakeRegistrar(), systemHotkeys: FakeSystemHotkeys(chords: []), sink: sink)

        #expect(registry.bind(.saveClipboard, to: .cmdK).isSuccess)

        #expect(sink.records.map(\.publicText) == ["hotkey.registered outcome=registered"])
        #expect(sink.records.first?.level == .info)
        #expect(sink.records.first?.category == .triggers)
    }

    /// OC-432-31. Given the OS refuses the chord, when bound, then one `outcome=failed` line and no `registered` line.
    /// Red if the failure path logs `registered` or nothing.
    @Test func oc43231_refusedBindLogsFailedNotRegistered() {
        let sink = HotkeySink()
        let registrar = FakeRegistrar()
        registrar.refused = [.cmdK]
        let registry = ShortcutRegistry(registrar: registrar, systemHotkeys: FakeSystemHotkeys(chords: []), sink: sink)

        _ = registry.bind(.saveClipboard, to: .cmdK)

        #expect(sink.records.map(\.publicText) == ["hotkey.registered outcome=failed"])
    }

    /// OC-432-32 (negative). Given a chord the validator rejects before the OS is asked (a system chord), when bound,
    /// then no registration line is logged (the OS was never asked), and the registrar saw zero calls.
    @Test func oc43232_validatorRejectionLogsNothing() {
        let sink = HotkeySink()
        let registrar = FakeRegistrar()
        let registry = ShortcutRegistry(registrar: registrar, systemHotkeys: FakeSystemHotkeys(chords: [.cmdK]), sink: sink)

        let result = registry.bind(.saveClipboard, to: .cmdK)

        #expect(!result.isSuccess)
        #expect(registrar.registerCalls == 0)
        #expect(sink.records.isEmpty)
    }
}
