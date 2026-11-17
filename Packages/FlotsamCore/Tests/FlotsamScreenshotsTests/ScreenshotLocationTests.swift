import Foundation
import Testing
import FlotsamBase
@testable import FlotsamScreenshots

// FR-002-01 location resolution.
@Suite struct ScreenshotLocationTests {
    private func resolver(_ temp: TempFolder, location: String?) -> ScreenshotLocationResolver {
        ScreenshotLocationResolver(
            fileSystem: LocalFileSystem(), preferences: FixedPreferences(locationValue: location), home: temp.root)
    }

    @Test("FR-002-01 no override and no system location: watch ~/Desktop")
    func defaultDesktop() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let desktop = try temp.folder("Desktop")
        let location = resolver(temp, location: nil).resolve(override: nil)
        #expect(location == .watching(desktop))
        #expect(location.warning == nil)
    }

    @Test("AC-002-01 a valid system location with ~ is expanded and watched")
    func systemLocation() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        try temp.folder("Desktop")
        let shots = try temp.folder("Pictures/Shots")
        #expect(resolver(temp, location: "~/Pictures/Shots").resolve(override: nil).folder?.path == shots.path)
        #expect(resolver(temp, location: shots.path).resolve(override: nil).folder?.path == shots.path)
    }

    @Test("AC-002-01 a removed system folder falls back to Desktop with SSP-IO-001")
    func systemFallback() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        let desktop = try temp.folder("Desktop")
        let location = resolver(temp, location: "~/Pictures/Gone").resolve(override: nil)
        #expect(location == .usingDesktop(desktop))
        #expect(location.warning == .sspIo001)
    }

    @Test("FR-002-01 a system location that is a file, not a folder, falls back to Desktop")
    func systemLocationIsFile() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        try temp.folder("Desktop")
        try temp.file("NotAFolder")
        #expect(resolver(temp, location: "~/NotAFolder").resolve(override: nil).warning == .sspIo001)
    }

    @Test("FR-002-01 a system location that is a link to a folder watches the folder it points to")
    func systemLocationIsLink() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        try temp.folder("Desktop")
        let real = try temp.folder("Real")
        try FileManager.default.createSymbolicLink(at: temp.root.appendingPathComponent("Link"), withDestinationURL: real)
        let location = resolver(temp, location: "~/Link").resolve(override: nil)
        #expect(location.warning == nil)
        #expect(location.folder?.path == real.path)
    }

    @Test("AC-002-01 a valid override wins over the system location")
    func overrideWins() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        try temp.folder("Desktop")
        try temp.folder("Pictures/Shots")
        let mine = try temp.folder("Mine")
        let location = resolver(temp, location: "~/Pictures/Shots").resolve(override: mine)
        #expect(location == .watching(mine))
    }

    @Test("AC-002-01 a missing override pauses pickup with SSP-IO-003 and never uses Desktop or the system folder")
    func overrideMissing() throws {
        let temp = try TempFolder()
        defer { temp.cleanUp() }
        try temp.folder("Desktop")
        try temp.folder("Pictures/Shots")
        let location = resolver(temp, location: "~/Pictures/Shots")
            .resolve(override: temp.root.appendingPathComponent("Gone"))
        #expect(location == .paused)
        #expect(location.folder == nil)
        #expect(location.warning == .sspIo003)
    }

    @Test("FR-002-03 a permission refusal is recognised from either error domain; other failures are not")
    func permissionDenied() {
        func error(_ domain: String, _ code: Int) -> FlotsamError {
            FlotsamError(.sysInt001, "test", underlying: UnderlyingErrorInfo(domain: domain, code: code))
        }
        #expect(ScreenshotFolderAccess.isPermissionDenied(error(NSCocoaErrorDomain, NSFileReadNoPermissionError)))
        #expect(ScreenshotFolderAccess.isPermissionDenied(error(NSPOSIXErrorDomain, Int(EPERM))))
        #expect(ScreenshotFolderAccess.isPermissionDenied(error(NSPOSIXErrorDomain, Int(EACCES))))
        #expect(!ScreenshotFolderAccess.isPermissionDenied(error(NSCocoaErrorDomain, NSFileReadNoSuchFileError)))
        #expect(!ScreenshotFolderAccess.isPermissionDenied(FlotsamError(.sysInt001, "no cause")))
    }
}
