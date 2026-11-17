/// The paste-back timing constants (FR-003-15, FR-003-16, ADR-0005). One home, so the Library and triggers wait
/// identically.
public enum PasteTiming {
    /// Pause after the panel is gone and before the target is checked, so the target has taken focus back.
    public static let settle: Duration = .milliseconds(40)
    /// How long the target app may take to become frontmost again before the paste is abandoned.
    public static let targetWindow: Duration = .milliseconds(250)
    /// Poll interval while waiting for the panel to disappear or the target to come back.
    public static let pollInterval: Duration = .milliseconds(10)
}
