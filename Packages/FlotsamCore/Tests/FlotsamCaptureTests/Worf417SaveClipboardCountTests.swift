import Foundation
import Testing
import FlotsamBase
@testable import FlotsamStorage
@testable import FlotsamCapture

/// TASK-417 / OC-WSC-011 / FR-001-18 b boundary: only changeCount INCREMENTS count, and three of them still suspend.
@MainActor
@Suite("TASK-417 worf: Save Clipboard empty-change counting", .serialized, .timeLimit(.minutes(2)))
struct Worf417SaveClipboardCountTests {
    /// OC-417-W3. given empty changes A (pressed 3 times), B (pressed twice), then C, when Save Clipboard is pressed
    /// on each, then the first five presses report CAP-VAL-001 and only the press on the THIRD DISTINCT change C
    /// reports CAP-PRM-001. Red if repeats on one changeCount count (suspends at press 3), or if no empty change ever
    /// counts (C stays CAP-VAL-001).
    @Test("OC-417-W3 three presses on one change count once; the third distinct empty change still suspends")
    func thirdDistinctChangeSuspends() async throws {
        let rig = try await GapRig()
        defer { Task { await rig.cleanUp() } }
        rig.settings.set(CaptureMode.curated, for: SettingKeys.captureMode)

        var codes: [ErrorCode] = []
        func press() async {
            if case .rejected(let error) = await rig.capture.saveClipboardNow() { codes.append(error.code) }
        }
        rig.pasteboard.copy([:])           // change A
        await press(); await press(); await press()
        rig.pasteboard.copy([:])           // change B
        await press(); await press()
        rig.pasteboard.copy([:])           // change C
        await press()

        #expect(codes == [.capVal001, .capVal001, .capVal001, .capVal001, .capVal001, .capPrm001])
    }
}
