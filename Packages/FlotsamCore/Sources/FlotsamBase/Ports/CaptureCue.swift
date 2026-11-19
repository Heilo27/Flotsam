import Foundation

/// What a capture cue says was captured (FR-001-30).
public enum CaptureCueKind: Sendable, Equatable {
    case clip
    case screenshot

    /// The catalogue key of the cue's one short line (FR-000-05).
    public var key: String {
        switch self {
        case .clip: "ui.cue.clip"
        case .screenshot: "ui.cue.screenshot"
        }
    }

    public var message: String { FlotsamStrings.text(forKey: key) ?? key }
}

/// The quiet capture cue (FR-001-30): the one place that decides whether a stored capture is announced. A caller says
/// "this was captured" after the item is stored, which is the same decision that keeps it (the policy gates of
/// FR-001-04 reject concealed-without-vault, transient and ignored-app copies before anything is stored, and a
/// concealed copy that is sealed never calls this), so the cue cannot disagree with the library. `capture.cue` is read
/// at each call, so turning it off applies to the next capture. The cue is not an error surface (FR-000-08): it is
/// never throttled, never a Notice, never logged, and holds no content.
///
/// `present` draws it. It owns the one-shot dismiss and must not take focus; it may be called from any thread.
public struct CaptureCue: Sendable {
    private let isEnabled: @Sendable () -> Bool
    private let present: @Sendable (CaptureCueKind) -> Void

    public init(settings: SettingsStore, present: @escaping @Sendable (CaptureCueKind) -> Void) {
        self.isEnabled = { settings.value(SettingKeys.captureCue) }
        self.present = present
    }

    public func captured(_ kind: CaptureCueKind) {
        guard isEnabled() else { return }
        present(kind)
    }
}
