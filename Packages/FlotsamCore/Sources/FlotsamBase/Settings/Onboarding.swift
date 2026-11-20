import Foundation

/// The eight onboarding steps in order (FR-008-12).
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, clipboard, accessibility, inputMonitoring, screenshots, hotkey, loginItem, done

    /// Catalogue keys for this step's title and its one-sentence purpose.
    public var titleKey: String { "ui.onboarding.\(name)Title" }
    public var purposeKey: String { "ui.onboarding.\(name)Purpose" }
    /// The title a permission step shows once its permission is on: a status ("Clipboard Access Is On"), not the instruction
    /// the title and purpose give before (FR-008-12, hill-climb r6). Nil for the steps that ask for no permission.
    public var grantedTitleKey: String? {
        switch self {
        case .clipboard, .accessibility, .inputMonitoring: "ui.onboarding.\(name)GrantedTitle"
        default: nil
        }
    }

    private var name: String {
        switch self {
        case .welcome: "welcome"
        case .clipboard: "clipboard"
        case .accessibility: "accessibility"
        case .inputMonitoring: "inputMonitoring"
        case .screenshots: "screenshots"
        case .hotkey: "hotkey"
        case .loginItem: "loginItem"
        case .done: "done"
        }
    }
}

/// Navigation through onboarding. It holds no settings: each step applies only what its own control set, so skipping
/// every step leaves the defaults, and closing part-way leaves nothing half-applied (FR-008-12).
public struct OnboardingFlow: Equatable, Sendable {
    public private(set) var current: OnboardingStep

    /// `resumingAt` is the step saved by `OnboardingProgress` after a quit mid-flow; nil starts at step 1.
    public init(resumingAt saved: OnboardingStep? = nil) {
        current = saved ?? .welcome
    }

    /// First launch shows onboarding by itself; afterwards only "Show Setup Guide…" does.
    public static func shouldShowAutomatically(settings: SettingsStore) -> Bool {
        !settings.value(SettingKeys.onboardingCompleted)
    }

    /// The one home of the resume rule (FR-008-12, OC-8098): only the automatic launch-time show picks up where a quit
    /// left off; "Show Setup Guide…" always starts at step 1, whatever is saved.
    public static func resumeStep(isAutomaticShow: Bool, saved: OnboardingStep?) -> OnboardingStep? {
        isAutomaticShow ? saved : nil
    }

    /// The one home of the step 5 import rule (FR-008-12, OC-8141): Continue imports the last 30 days only when the
    /// box is checked and pickup is on; step 5 never turns pickup on (FR-008-17).
    public static func shouldImportScreenshots(importRecent: Bool, pickupEnabled: Bool) -> Bool {
        importRecent && pickupEnabled
    }

    /// The one home of when onboarding asks macOS for the login item status (FR-008-15, TASK-460): only while the user is on
    /// step 7. Even a read of `SMAppService.mainApp.status` at launch makes Background Task Management record the app, and
    /// macOS then shows "Login Item Added" before the user has chosen anything.
    public static func readsLoginStatus(on step: OnboardingStep) -> Bool { step == .loginItem }

    /// Every step, in order: every supported macOS (26 and later) gates pasteboard reads, so step 2 always shows.
    public var steps: [OnboardingStep] { OnboardingStep.allCases }
    public var position: Int { (steps.firstIndex(of: current) ?? 0) + 1 }
    public var total: Int { steps.count }
    public var isFirst: Bool { position == 1 }
    public var isLast: Bool { position == total }

    /// Continue and Skip both move forward; Skip leaves the step's setting alone, which is the caller's business.
    public mutating func advance() {
        guard let index = steps.firstIndex(of: current), index + 1 < steps.count else { return }
        current = steps[index + 1]
    }

    public mutating func back() {
        guard let index = steps.firstIndex(of: current), index > 0 else { return }
        current = steps[index - 1]
    }
}

/// The resume point of an unfinished onboarding (FR-008-12): quitting with ⌘Q closes no window, so without this a
/// relaunch would show steps 1 to 3 again. It is progress, not a preference, so it is not a registry row (FR-008-01);
/// it is cleared when onboarding finishes or the window closes.
public struct OnboardingProgress: Sendable {
    static let keyName = "onboarding.resumeStep"
    private let store: any KeyValueStore

    public init(store: any KeyValueStore) { self.store = store }

    /// The step to resume at, or nil when none is saved or the saved value is not a step.
    public func savedStep() -> OnboardingStep? {
        guard let raw = store.string(forKey: Self.keyName), let number = Int(raw) else { return nil }
        return OnboardingStep(rawValue: number)
    }

    public func save(_ step: OnboardingStep) { store.setString(String(step.rawValue), forKey: Self.keyName) }

    public func clear() { store.removeValue(forKey: Self.keyName) }
}
