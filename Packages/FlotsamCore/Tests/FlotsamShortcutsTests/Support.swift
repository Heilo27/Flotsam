import Foundation
import FlotsamBase

/// A registrar that records what the registry asked of it and can refuse chords.
@MainActor
final class FakeRegistrar: HotkeyRegistrar {
    var refused: Set<Chord> = []
    private(set) var live: [UInt32: (chord: Chord, handler: @MainActor () -> Void)] = [:]
    private(set) var registerCalls = 0
    private(set) var unregisterAllCalls = 0
    private var next: UInt32 = 1

    func register(_ chord: Chord, handler: @escaping @MainActor () -> Void) -> FlotsamResult<HotkeyRegistration> {
        registerCalls += 1
        if refused.contains(chord) { return .failure(FlotsamError(.trgOs001, "refused by test")) }
        let handle = HotkeyRegistration(rawValue: next)
        next += 1
        live[handle.rawValue] = (chord, handler)
        return .success(handle)
    }

    func unregister(_ registration: HotkeyRegistration) { live[registration.rawValue] = nil }

    func unregisterAll() {
        unregisterAllCalls += 1
        live.removeAll()
    }

    var liveChords: Set<Chord> { Set(live.values.map(\.chord)) }

    /// Simulates the user pressing `chord`.
    func press(_ chord: Chord) {
        for entry in live.values where entry.chord == chord { entry.handler() }
    }
}

struct FakeSystemHotkeys: SystemHotkeyProvider {
    var chords: Set<Chord>
    func enabledSystemChords() -> Set<Chord> { chords }
}

extension Chord {
    static let cmdK = Chord(keyCode: 40, modifiers: .command)
    static let cmdJ = Chord(keyCode: 38, modifiers: .command)
    static let ctrlCmdV = Chord(keyCode: 9, modifiers: [.control, .command])
}

final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { values[key] = value } }
    func removeValue(forKey key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
}
