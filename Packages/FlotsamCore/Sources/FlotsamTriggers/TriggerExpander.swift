import FlotsamBase
import FlotsamPaste
import FlotsamStorage
import Foundation

/// How one expansion ended (FR-005-14, FR-005-15). The engine reads it only for tests and the `trigger.matched` log.
public enum ExpansionOutcome: Sendable, Equatable {
    /// The item was pasted over the typed trigger.
    case expanded
    /// The recheck at step 2 found Secure Event Input on, or the app now excluded. Nothing was changed.
    case suppressed(TriggerSuppression)
    /// A step failed and the failure path of FR-005-15 ran. Carries the code that was shown or logged.
    case failed(ErrorCode)
}

/// FR-005-14 / FR-005-15: turns a `TriggerMatch` into a pasted item and puts the typed text back when it cannot.
///
/// Runs on the main actor, off the tap thread: the tap only decides and swallows the boundary key, then hands the match
/// here. One expansion at a time is the caller's job (`TriggerEngine` runs them from a single serial consumer), because
/// two overlapping expansions would fight over the one pasteboard.
///
/// Step order differs from FR-005-14 in one place that is not observable: the pasteboard snapshot (step 3) is taken
/// before the variables are expanded (step 1's second half) because `{clipboard}` is defined as the snapshot's plain
/// text (FR-005-17). Steps 1 to 4 share one failure path and nothing has been typed or deleted until step 5, so no
/// outcome depends on which of them ran first.
@MainActor
public final class TriggerExpander {
    private let store: any PasteItemStore
    private let expansion: PasteExpansion
    private let paste: PasteService
    private let keys: any TriggerKeyPoster
    private let keyboard: any KeyboardEnvironment
    private let snapshot: TriggerSnapshotStore
    private let permissions: any PermissionProbe
    private let reporter: ErrorReporter
    private let clock: any WallClock
    private let sink: any LogSink
    private let ownBundleId: String

    public init(
        store: any PasteItemStore, pasteboard: any PasteboardPort, files: any FileSystemPort,
        codec: any RichTextCodec, preserver: ClipboardPreserver, ownWrites: OwnWriteLedger, paste: PasteService,
        keys: any TriggerKeyPoster, keyboard: any KeyboardEnvironment, snapshot: TriggerSnapshotStore,
        permissions: any PermissionProbe, reporter: ErrorReporter, clock: any WallClock, ownBundleId: String,
        calendar: Calendar = .current, locale: Locale = .current, sink: any LogSink = OSLogSink()
    ) {
        self.store = store
        self.expansion = PasteExpansion(
            pasteboard: pasteboard, files: files, codec: codec, preserver: preserver, ownWrites: ownWrites,
            clock: clock, calendar: calendar, locale: locale)
        self.paste = paste
        self.keys = keys
        self.keyboard = keyboard
        self.snapshot = snapshot
        self.permissions = permissions
        self.reporter = reporter
        self.clock = clock
        self.ownBundleId = ownBundleId
        self.sink = sink
    }

    /// What steps 1 to 6 leave for steps 7 and 8.
    private typealias Staged = PasteExpansion.Staged

    /// `ExpansionOutcome` is not an `Error`, so `Result` does not fit.
    private enum Stage {
        case pasted(Staged)
        case ended(ExpansionOutcome)
    }

    /// Runs the sequence for one match. Never throws; every failure has already been surfaced when this returns.
    public func expand(_ match: TriggerMatch) async -> ExpansionOutcome {
        let span = Signposts.begin(.triggerExpand)
        let staged = await stage(match)
        // `trigger.expand` is boundary key to ⌘V posted (FR-005-21), so it ends before bookkeeping and the restore wait.
        span.end()
        let ready: Staged
        switch staged {
        case .pasted(let value): ready = value
        case .ended(let outcome): return outcome
        }

        FlotsamLog.log(.triggerMatched(true), sink: sink)
        // Step 7. The item is pasted already, so a bookkeeping failure is logged, not shown.
        if case .failure(let error) = await store.recordPaste(of: match.itemId) {
            FlotsamLog.log(error, category: .triggers, sink: sink)
        }
        // Step 8.
        await expansion.finish(ready)
        return .expanded
    }

    // MARK: Steps 1 to 6

    private func stage(_ match: TriggerMatch) async -> Stage {
        // Step 1: load. The recheck follows the await because the user keeps typing and switching while the read runs.
        let content: ItemContent
        switch await store.content(of: match.itemId) {
        case .success(let loaded): content = loaded
        case .failure(let error): return .ended(await abortBeforeDelete(match, cause: error))
        }

        // Step 2.
        if let aborted = await recheck(match) { return .ended(aborted) }

        // Steps 3 and 4, with step 1's variables: snapshot, expand against it, write with own-write markers (FR-001-03).
        let staged: Staged
        switch expansion.stage(content: content, itemId: match.itemId) {
        case .success(let value): staged = value
        case .failure(let error): return .ended(await abortBeforeDelete(match, cause: error))
        }

        // Step 5, addressed to the process the trigger was typed into (FR-005-14). `postKeyPress` creates every event
        // before posting any and re-checks that the app is still frontmost, so `false` means none was posted and the
        // typed trigger is still on screen; that is the same state as a step 1 to 4 failure.
        guard keys.postKeyPress(keyCode: TriggerKeys.backspace, count: match.triggerLength, to: match.app) else {
            return .ended(await abortBeforeDelete(match, cause: nil))
        }

        // Step 6.
        await clock.sleep(for: PasteTiming.settle)
        if case .failure(let error) = await paste.postPaste(target: match.app) {
            return .ended(await abortAfterDelete(match, cause: error))
        }
        return .pasted(staged)
    }

    /// Step 2: the world may have changed between the boundary key and now. `nil` means carry on.
    private func recheck(_ match: TriggerMatch) async -> ExpansionOutcome? {
        if case .copyOnly(let error) = PasteGate.outcome(probe: permissions) {
            return await abortBeforeDelete(match, report: error)
        }
        // The key was meant for the app the user was in; if that is no longer frontmost, nothing is re-posted.
        guard keyboard.frontmostApp() == match.app else { return await abortBeforeDelete(match, cause: nil) }
        if let bundleId = match.app.bundleId,
            snapshot.policy.excludes(bundleId: bundleId, ownBundleId: ownBundleId)
        {
            await reporter.report(FlotsamError(.trgPol002, "Frontmost app excluded at expansion"), origin: .background)
            repostBoundary(match)
            return .suppressed(.excludedApp)
        }
        if keyboard.isSecureEventInputEnabled() {
            await reporter.report(FlotsamError(.trgPol001, "Secure input on at expansion"), origin: .background)
            repostBoundary(match)
            return .suppressed(.secureInput)
        }
        return nil
    }

    // MARK: FR-005-15 failure paths

    /// Steps 1 to 5 (and the step 2 recheck) failed, so nothing was deleted: re-post the swallowed boundary key, so the
    /// app sees exactly what the user typed, and show `TRG-OS-002`. The item stays on the pasteboard once step 4 has
    /// written it, as `LIB-OS-001` leaves it; the previous clipboard is not restored.
    private func abortBeforeDelete(_ match: TriggerMatch, cause: FlotsamError?) async -> ExpansionOutcome {
        await abortBeforeDelete(match, report: expansionFailure(cause))
    }

    private func abortBeforeDelete(_ match: TriggerMatch, report error: FlotsamError) async -> ExpansionOutcome {
        if keyboard.frontmostApp() == match.app { repostBoundary(match) }
        await reporter.report(error, origin: .userInitiated)
        return .failed(error.code)
    }

    /// Step 6 failed after the backspaces were posted: the trigger is gone from the field. Re-type it as a Unicode
    /// string, then the boundary key, so the user is no worse off. Best effort (`TRG-OS-002` promises only that
    /// Flotsam tried). Only when the typed-into app is still frontmost: if the user has moved on, re-typing would put
    /// the word into whatever they are in now.
    private func abortAfterDelete(_ match: TriggerMatch, cause: FlotsamError) async -> ExpansionOutcome {
        if keyboard.frontmostApp() == match.app {
            _ = keys.postText(match.typedText, to: match.app)
            repostBoundary(match)
        }
        let error = expansionFailure(cause)
        await reporter.report(error, origin: .userInitiated)
        return .failed(error.code)
    }

    private func repostBoundary(_ match: TriggerMatch) {
        _ = keys.postKeyPress(keyCode: match.boundaryKeyCode, count: 1, to: match.app)
    }

    /// The one error every failed step shows. The cause is kept as a code in the context, never as text.
    private func expansionFailure(_ cause: FlotsamError?) -> FlotsamError {
        FlotsamError(
            .trgOs002, "Trigger expansion failed",
            context: cause.map { [.code: .code($0.code)] } ?? [:])
    }
}
