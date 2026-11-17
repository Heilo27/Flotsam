import Foundation

/// The eight onboarding steps in order (FR-008-12).
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, clipboard, accessibility, inputMonitoring, screenshots, hotkey, loginItem, done

    /// Catalogue keys for this step's title and its one-sentence purpose.
    public var titleKey: String { "ui.onboarding.\(name)Title" }
    public var purposeKey: String { "ui.onboarding.\(name)Purpose" }

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
    /// False on macOS versions that do not gate pasteboard reads (FRD-001 FR-001-18): step 2 is then skipped.
    public let gatesPasteboard: Bool
    public private(set) var current: OnboardingStep

    public init(gatesPasteboard: Bool) {
        self.gatesPasteboard = gatesPasteboard
        current = .welcome
    }

    /// First launch shows onboarding by itself; afterwards only "Show Setup Guide…" does.
    public static func shouldShowAutomatically(settings: SettingsStore) -> Bool {
        !settings.value(SettingKeys.onboardingCompleted)
    }

    public var steps: [OnboardingStep] { OnboardingStep.allCases.filter { $0 != .clipboard || gatesPasteboard } }
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
