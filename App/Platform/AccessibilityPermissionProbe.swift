import ApplicationServices
import FlotsamBase

/// Accessibility trust, asked fresh on every call so a grant takes effect without a relaunch (FR-008-14).
/// `AXIsProcessTrusted()` never prompts; the prompt is the Settings flow's job.
struct AccessibilityPermissionProbe: PermissionProbe {
    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
}
