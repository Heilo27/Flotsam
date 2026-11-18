import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// FR-002-06 recognition and the FR-002-04 direct-children rule.
@Suite struct ScreenshotRecognitionTests {
    private let yes = TempFolder.screenCaptureAttribute(true)
    private let no = TempFolder.screenCaptureAttribute(false)

    @Test("FR-002-06 the attribute decides when present, the name only when it is absent")
    func attributeWins() {
        #expect(ScreenshotRecognizer.qualifies(fileName: "holiday.png", attribute: yes, customPrefix: nil))
        #expect(!ScreenshotRecognizer.qualifies(fileName: "Screenshot 2026-11-17 at 10.00.00.png", attribute: no, customPrefix: nil))
        #expect(ScreenshotRecognizer.qualifies(fileName: "Screenshot 2026-11-17 at 10.00.00.png", attribute: nil, customPrefix: nil))
        #expect(!ScreenshotRecognizer.qualifies(fileName: "holiday.png", attribute: nil, customPrefix: nil))
        #expect(!ScreenshotRecognizer.qualifies(fileName: "holiday.png", attribute: Data("junk".utf8), customPrefix: nil))
    }

    @Test(
        "FR-002-06 only image extensions qualify, in any case",
        arguments: [
            ("Screenshot a.png", true), ("Screenshot a.PNG", true), ("Screenshot a.jpg", true), ("Screenshot a.jpeg", true),
            ("Screenshot a.tiff", true), ("Screenshot a.tif", true), ("Screenshot a.HEIC", true),
            ("Screen Recording a.mov", false), ("Screenshot a.mov", false), ("Screenshot a.pdf", false),
            ("Screenshot a.gif", false), ("Screenshot a", false),
        ])
    func extensions(name: String, expected: Bool) {
        #expect(ScreenshotRecognizer.qualifies(fileName: name, attribute: yes, customPrefix: nil) == expected)
    }

    @Test("FR-002-06 a hidden temporary name never qualifies, even with the attribute")
    func hidden() {
        #expect(!ScreenshotRecognizer.qualifies(fileName: ".Screenshot 2026-11-17.png", attribute: yes, customPrefix: nil))
    }

    @Test(
        "FR-002-06 localised system names from screencaptureui (spike S-8)",
        arguments: [
            "Capture d\u{2019}écran 2026-11-17 à 10.00.00.png",
            "Capture d\u{2019}e\u{0301}cran 2026-11-17 à 10.00.00.png",  // decomposed é (NFD)
            "Bildschirmfoto 2026-11-17 um 10.00.00.png",
            "Captura de pantalla 2026-11-17 a las 10.00.00.png",
            "Scherm\u{00AD}afbeelding 2026-11-17 om 10.00.00.png",  // soft hyphen, as in the system catalogue
            "Schermafbeelding 2026-11-17 om 10.00.00.png",
            "Screenshot 2026-11-17 alle 10.00.00.png",
            "スクリーンショット 2026-11-17 10.00.00.png",
            "截屏2026-11-17 10.00.00.png",
            "截圖 2026-11-17 10.00.00.png",
            "螢幕截圖 2026-11-17 10.00.00.png",
            "스크린샷 2026-11-17 10.00.00.png",
            "\u{200F}لقطة الشاشة 2026-11-17.png",  // right-to-left mark first, as the Arabic format writes it
            "Screen Shot 2021-01-01 at 10.00.00.png",
        ])
    func localisedNames(name: String) {
        #expect(ScreenshotRecognizer.qualifies(fileName: name, attribute: nil, customPrefix: nil))
    }

    @Test("FR-002-06 the user's custom name prefix counts")
    func customPrefix() {
        #expect(ScreenshotRecognizer.qualifies(fileName: "Grab 2026-11-17.png", attribute: nil, customPrefix: "Grab"))
        #expect(!ScreenshotRecognizer.qualifies(fileName: "Grab 2026-11-17.png", attribute: nil, customPrefix: nil))
        #expect(!ScreenshotRecognizer.qualifies(fileName: "Grab 2026-11-17.png", attribute: nil, customPrefix: ""))
    }

    @Test("AC-002-05 a folder of mixed files yields only the png screenshot and the jpg screenshot")
    func ac00205() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let folder = try temp.folder("Shots")
        let systemShot = try temp.file("Shots/Screenshot 2026-11-17 at 10.00.00.png", screenCapture: true)
        let jpgShot = try temp.file("Shots/Screenshot 2026-11-17 at 10.00.01.jpg")
        try temp.file("Shots/Screen Recording 2026-11-17 at 10.00.02.mov", screenCapture: true)
        try temp.file("Shots/Screenshot 2026-11-17 at 10.00.03.pdf")
        try temp.file("Shots/.Screenshot 2026-11-17 at 10.00.04.png", screenCapture: true)
        try temp.file("Shots/Sub/Screenshot 2026-11-17 at 10.00.05.png", screenCapture: true)
        try temp.file("Shots/holiday.png")
        let elsewhere = try temp.file("Other/Screenshot 2026-11-17 at 10.00.06.png", screenCapture: true)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("Screenshot link.png"), withDestinationURL: elsewhere)

        let scanner = ScreenshotFolderScanner(fileSystem: LocalFileSystem(), preferences: FixedPreferences())
        let found = try scanner.scan(folder).get().map(\.url.lastPathComponent).sorted()
        #expect(found == [systemShot.lastPathComponent, jpgShot.lastPathComponent].sorted())
    }

    @Test("FR-002-09 a scanned file carries its birth date and size")
    func birthDate() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let url = try temp.file("Screenshot b.png", bytes: Data(repeating: 7, count: 321))
        let born = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: born, .modificationDate: Date()], ofItemAtPath: url.path)
        let file = ScreenshotFolderScanner(fileSystem: LocalFileSystem(), preferences: FixedPreferences()).candidate(url, in: temp.root)
        #expect(file?.createdAt == born)
        #expect(file?.byteSize == 321)
    }
}
