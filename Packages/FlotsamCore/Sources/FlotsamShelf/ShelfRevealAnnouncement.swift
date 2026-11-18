import FlotsamBase

/// What happens the moment the Shelf is about to appear, kept apart from AppKit so a test can reach it (the app has
/// no test target): the Library is told to hide, because only one Flotsam panel is open at a time (FR-006-04), and one
/// Info line records the reveal (FR-006-18).
public enum ShelfRevealAnnouncement {
    /// Hides the Library first, then writes `shelf.reveal` carrying the trigger type and nothing else: never a clip,
    /// file or app name. `hideLibrary` is the app's rule for closing its Library panel; the Shelf only announces.
    @MainActor
    public static func announce(
        _ trigger: ShelfTrigger, hideLibrary: (@MainActor () -> Void)?, sink: any LogSink = OSLogSink()
    ) {
        hideLibrary?()
        FlotsamLog.log(.shelf(.reveal, outcome: .revealed, detail: .trigger(trigger)), sink: sink)
    }
}
