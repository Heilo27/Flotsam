import AppKit
import Carbon.HIToolbox
import FlotsamBase
import FlotsamTriggers

/// What the match decision asks the system (FR-005-13): Secure Event Input, input-method composition, and the
/// frontmost application. It is read from the tap thread, so the two answers that must come from the main thread (the
/// Text Input Source and `NSWorkspace`) are cached here and refreshed from their change notifications. Secure Event
/// Input is a plain thread-safe Carbon call.
///
/// A change of frontmost application also clears the typed word (FR-005-11), which is why the reset signal lives here:
/// this is the one observer of that change.
@MainActor
final class SystemKeyboardEnvironment: KeyboardEnvironment {
    private struct Cache: Sendable {
        var frontmost: FrontmostApp?
        var inputMethodActive = true  // fail closed until the first read
    }

    /// The value of `kTISNotifySelectedKeyboardInputSourceChanged`, spelled out because Swift 6 flags the C global.
    private static let inputSourceChanged = Notification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged")

    private let cache = LockedValue(Cache())
    private let resetSignal: TriggerResetSignal
    private let frontmostProvider = WorkspaceFrontmostAppProvider()
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    init(resetSignal: TriggerResetSignal) {
        self.resetSignal = resetSignal
        refreshFrontmost()
        refreshInputSource()

        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observers = [
            (workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshFrontmost()
                    self?.resetSignal.request()
                }
            }),
            (distributed, distributed.addObserver(forName: Self.inputSourceChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshInputSource() }
            }),
        ]
    }

    isolated deinit {
        for observer in observers { observer.center.removeObserver(observer.token) }
    }

    nonisolated func isSecureEventInputEnabled() -> Bool { IsSecureEventInputEnabled() }

    nonisolated func isInputMethodActive() -> Bool { cache.value.inputMethodActive }

    nonisolated func frontmostApp() -> FrontmostApp? { cache.value.frontmost }

    private func refreshFrontmost() {
        let app = frontmostProvider.frontmost()
        cache.withLock { $0.frontmost = app }
    }

    /// An input method is anything but a plain keyboard layout (Japanese, Chinese and Korean composition are input
    /// modes or input methods). An unreadable source counts as an input method: fail closed.
    private func refreshInputSource() {
        let active: Bool
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType)
        {
            let type = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
            active = (type as String) != (kTISTypeKeyboardLayout as String)
        } else {
            active = true
        }
        cache.withLock { $0.inputMethodActive = active }
    }
}
