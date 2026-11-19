// swift-tools-version: 6.0
// Layering and import rules: docs/adr/0001-module-structure.md. Checked by bin/check-architecture.sh.
import PackageDescription

let package = Package(
    name: "FlotsamCore",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FlotsamBase", targets: ["FlotsamBase"]),
        .library(name: "FlotsamStorage", targets: ["FlotsamStorage"]),
        .library(name: "FlotsamPayload", targets: ["FlotsamPayload"]),
        .library(name: "FlotsamPaste", targets: ["FlotsamPaste"]),
        .library(name: "FlotsamCapture", targets: ["FlotsamCapture"]),
        .library(name: "FlotsamScreenshots", targets: ["FlotsamScreenshots"]),
        .library(name: "FlotsamLibrary", targets: ["FlotsamLibrary"]),
        .library(name: "FlotsamShortcuts", targets: ["FlotsamShortcuts"]),
        .library(name: "FlotsamTriggers", targets: ["FlotsamTriggers"]),
        .library(name: "FlotsamShelf", targets: ["FlotsamShelf"]),
    ],
    dependencies: [
        // The only third-party dependency (ADR-0010). Exact pin; Package.resolved is committed.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
    ],
    targets: [
        .target(
            name: "FlotsamBase",
            dependencies: [],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "FlotsamBaseTests", dependencies: ["FlotsamBase"]),
        .target(
            name: "FlotsamStorage",
            dependencies: ["FlotsamBase", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "FlotsamStorageTests", dependencies: ["FlotsamStorage", "FlotsamBase"]),
        .target(
            name: "FlotsamPayload",
            dependencies: ["FlotsamBase"]
        ),
        .testTarget(name: "FlotsamPayloadTests", dependencies: ["FlotsamPayload", "FlotsamBase"]),
        .target(
            name: "FlotsamPaste",
            dependencies: ["FlotsamBase", "FlotsamStorage"]
        ),
        .testTarget(name: "FlotsamPasteTests", dependencies: ["FlotsamPaste", "FlotsamBase", "FlotsamStorage"]),
        .target(
            name: "FlotsamCapture",
            dependencies: ["FlotsamBase", "FlotsamStorage", "FlotsamPayload"]
        ),
        .testTarget(name: "FlotsamCaptureTests", dependencies: ["FlotsamCapture", "FlotsamShortcuts", "FlotsamBase", "FlotsamStorage", "FlotsamPayload"]),
        .target(
            name: "FlotsamScreenshots",
            dependencies: ["FlotsamBase", "FlotsamStorage", "FlotsamPayload"]
        ),
        .testTarget(name: "FlotsamScreenshotsTests", dependencies: ["FlotsamScreenshots", "FlotsamBase", "FlotsamStorage", "FlotsamPayload"]),
        .target(
            name: "FlotsamLibrary",
            dependencies: ["FlotsamBase", "FlotsamStorage", "FlotsamPaste"]
        ),
        .testTarget(name: "FlotsamLibraryTests", dependencies: ["FlotsamLibrary", "FlotsamBase", "FlotsamStorage", "FlotsamPaste"]),
        .target(
            name: "FlotsamShortcuts",
            dependencies: ["FlotsamBase", "FlotsamStorage", "FlotsamPaste"]
        ),
        .testTarget(name: "FlotsamShortcutsTests", dependencies: ["FlotsamShortcuts", "FlotsamShelf", "FlotsamBase", "FlotsamPaste", "FlotsamStorage"]),
        .target(
            name: "FlotsamTriggers",
            dependencies: ["FlotsamBase", "FlotsamStorage", "FlotsamPaste"]
        ),
        .testTarget(
            name: "FlotsamTriggersTests",
            dependencies: ["FlotsamTriggers", "FlotsamBase", "FlotsamStorage", "FlotsamPaste", "FlotsamCapture", "FlotsamPayload"]
        ),
        .target(
            name: "FlotsamShelf",
            dependencies: ["FlotsamBase", "FlotsamStorage", "FlotsamPayload"]
        ),
        .testTarget(name: "FlotsamShelfTests", dependencies: ["FlotsamShelf", "FlotsamBase", "FlotsamStorage", "FlotsamPayload"]),
        // S2 perf harnesses (opt-in, measurement only): every test is gated on FLOTSAM_PERF=1, so a plain `swift test`
        // skips them. Sources symlink the storage fixture and the App's SystemPasteboard so nothing is copied; see bin/perf.sh.
        // Exception: Oc2067Oc2068PerformanceTests (OC-2067 / OC-2068 / AC-002-11) is NOT gated; it asserts the screenshot
        // pickup contracts on every `swift test`. It lives here, not in FlotsamScreenshotsTests, because it runs the real
        // importer for minutes and that target's signpost tests read process-wide `screenshot.import` intervals: in one
        // process the two interfere. A test target is its own process.
        .testTarget(
            name: "FlotsamPerfTests",
            dependencies: ["FlotsamBase", "FlotsamStorage", "FlotsamPayload", "FlotsamCapture", "FlotsamScreenshots"]
        ),
        // Worf (TASK-318): compiles the App-target editor model and its recorder (symlinked sources) so the editor's
        // save and validation rules run under `swift test` with no app launch.
        .testTarget(
            name: "FlotsamAppModelTests",
            dependencies: [
                "FlotsamBase", "FlotsamStorage", "FlotsamPaste", "FlotsamShortcuts", "FlotsamTriggers",
            ]
        ),
    ]
)
