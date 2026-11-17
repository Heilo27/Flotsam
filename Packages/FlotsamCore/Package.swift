// swift-tools-version: 6.0
// Layering and import rules: docs/adr/0001-module-structure.md. Checked by bin/check-architecture.sh.
import PackageDescription

let package = Package(
    name: "FlotsamCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
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
        .testTarget(name: "FlotsamPasteTests", dependencies: ["FlotsamPaste", "FlotsamBase"]),
        .target(
            name: "FlotsamCapture",
            dependencies: ["FlotsamBase", "FlotsamStorage", "FlotsamPayload"]
        ),
        .testTarget(name: "FlotsamCaptureTests", dependencies: ["FlotsamCapture", "FlotsamBase", "FlotsamStorage", "FlotsamPayload"]),
        .target(
            name: "FlotsamScreenshots",
            dependencies: ["FlotsamBase", "FlotsamStorage", "FlotsamPayload"]
        ),
        .testTarget(name: "FlotsamScreenshotsTests", dependencies: ["FlotsamScreenshots", "FlotsamBase"]),
        .target(
            name: "FlotsamLibrary",
            dependencies: ["FlotsamBase", "FlotsamStorage", "FlotsamPaste"]
        ),
        .testTarget(name: "FlotsamLibraryTests", dependencies: ["FlotsamLibrary", "FlotsamBase"]),
        .target(
            name: "FlotsamShortcuts",
            dependencies: ["FlotsamBase", "FlotsamStorage", "FlotsamPaste"]
        ),
        .testTarget(name: "FlotsamShortcutsTests", dependencies: ["FlotsamShortcuts", "FlotsamBase"]),
        .target(
            name: "FlotsamTriggers",
            dependencies: ["FlotsamBase", "FlotsamStorage", "FlotsamPaste"]
        ),
        .testTarget(name: "FlotsamTriggersTests", dependencies: ["FlotsamTriggers", "FlotsamBase"]),
        .target(
            name: "FlotsamShelf",
            dependencies: ["FlotsamBase", "FlotsamStorage", "FlotsamPayload"]
        ),
        .testTarget(name: "FlotsamShelfTests", dependencies: ["FlotsamShelf", "FlotsamBase"]),
    ]
)
