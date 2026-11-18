import Foundation
import Testing

@testable import FlotsamBase

@Suite("FR-002-12: the Imported {n} HUD text and the Settings button label")
struct Task446ImportHUDTests {
    @Test("the HUD reads Imported {n} from the catalogue")
    func hudText() {
        #expect(ScreenshotImportHUD.message(count: 0) == "Imported 0")
        #expect(ScreenshotImportHUD.message(count: 500) == "Imported 500")
        #expect(ScreenshotImportHUD.message(count: -4) == "Imported 0")
    }

    @Test("the Settings button label is in the catalogue under its SettingsString key")
    func buttonLabel() {
        #expect(SettingsString.importRecentScreenshots.key == "ui.settings.importRecentScreenshots")
        #expect(SettingsString.importRecentScreenshots.text == "Import Recent Screenshots")
    }
}
