#if DEBUG
import AppKit
import FlotsamBase
import FlotsamPayload
import FlotsamStorage
import Foundation

/// The fixture library for the screenshot harness (bin/shots.sh, docs/SCREENSHOTS.md). Debug builds only.
///
/// Everything here is invented and generic: no real person, account, product or personal data. The 40 items are written
/// into the isolated database through the same `IngestActor` a real copy goes through, so they look exactly like captured
/// clips. Timestamps are placed in the middle of a relative-time bucket (minutes and hours, all within 23 hours, so no
/// calendar-day wording is involved) and the labels read the same on every run.
@MainActor
enum ShotsFixtures {
    /// The items the stages need to find again.
    struct Seeded {
        var ids: [String: UUID] = [:]
    }

    private struct Entry {
        let label: String
        let make: (Date) -> IngestCandidate?
    }

    private static let safari = SourceApp(bundleId: "com.apple.Safari", name: "Safari")
    private static let notes = SourceApp(bundleId: "com.apple.Notes", name: "Notes")
    private static let textEdit = SourceApp(bundleId: "com.apple.TextEdit", name: "TextEdit")
    private static let terminal = SourceApp(bundleId: "com.apple.Terminal", name: "Terminal")
    private static let preview = SourceApp(bundleId: "com.apple.Preview", name: "Preview")
    private static let finder = SourceApp(bundleId: "com.apple.finder", name: "Finder")

    private static let swiftSnippet = """
        struct Greeting {
            let name: String

            func message(hour: Int) -> String {
                let part = hour < 12 ? "morning" : "day"
                return "Good \\(part), \\(name)"
            }
        }
        """

    /// Seconds before "now" for the item at `index` (0 is the newest): minutes for the first ten, then hours up to 21.
    /// Always half a unit past a boundary, so a few seconds of run time never changes a label.
    private static func age(at index: Int) -> TimeInterval {
        if index < 10 { return TimeInterval((index * 5 + 2) * 60 + 30) }
        let hours = 1 + (index - 10) * 20 / 30
        return TimeInterval(hours * 3600 + 1800)
    }

    private static func text(_ label: String, _ body: String, _ source: SourceApp) -> Entry {
        Entry(label: label) { date in
            IngestCandidate(
                kind: .text, contentKey: ContentKey.text(Data(body.utf8)), plainText: body, source: source,
                origin: .pasteboard, occurredAt: date)
        }
    }

    private static func typed(_ label: String, _ kind: ItemKind, _ body: String, _ source: SourceApp) -> Entry {
        Entry(label: label) { date in
            IngestCandidate(
                kind: kind, contentKey: ContentKey.text(Data(body.utf8)), plainText: body, source: source,
                origin: .pasteboard, occurredAt: date)
        }
    }

    private static func image(_ label: String, width: Int, height: Int, hue: CGFloat, _ source: SourceApp) -> Entry {
        Entry(label: label) { date in
            guard let png = drawnPNG(width: width, height: height, hue: hue) else { return nil }
            return IngestCandidate(
                kind: .image, contentKey: ContentKey.image(png),
                representations: [PasteboardRepresentation(uti: "public.png", data: png)], source: source,
                origin: .pasteboard, occurredAt: date)
        }
    }

    private static func file(_ label: String, path: String) -> Entry {
        Entry(label: label) { date in
            IngestCandidate(
                kind: .file, contentKey: ContentKey.files(paths: [path]),
                members: [IngestMember(path: path, bookmark: nil, isDirectory: false)], source: finder,
                origin: .pasteboard, occurredAt: date)
        }
    }

    private static func bundle(_ label: String, paths: [String]) -> Entry {
        Entry(label: label) { date in
            IngestCandidate(
                kind: .bundle, contentKey: ContentKey.files(paths: paths),
                members: paths.map { IngestMember(path: $0, bookmark: nil, isDirectory: false) }, source: finder,
                origin: .pasteboard, occurredAt: date)
        }
    }

    /// A generated picture: a diagonal two-tone gradient with a few soft circles. Fully deterministic.
    private static func drawnPNG(width: Int, height: Int, hue: CGFloat) -> Data? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let top = NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor
        let bottom = NSColor(hue: fmod(hue + 0.12, 1), saturation: 0.75, brightness: 0.55, alpha: 1).cgColor
        guard let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) else { return nil }
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        let unit = CGFloat(min(width, height))
        for (index, scale) in [0.34, 0.2, 0.12].enumerated() {
            let radius = unit * scale
            let centre = CGPoint(x: CGFloat(width) * (0.3 + 0.22 * CGFloat(index)), y: CGFloat(height) * (0.62 - 0.14 * CGFloat(index)))
            context.setFillColor(NSColor(white: 1, alpha: 0.22 - 0.05 * CGFloat(index)).cgColor)
            context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        }
        guard let picture = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:])
    }

    /// Writes the files the file and bundle items point at, so none is flagged Missing.
    private static func makeFiles(in folder: URL) -> [String: String] {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let contents = [
            "report": ("quarterly-summary.txt", "Quarterly summary\nRevenue steady, costs down, two launches on track.\n"),
            "budget": ("budget-draft.csv", "item,amount\nhosting,120\ndesign,300\nsnacks,45\n"),
            "outline": ("talk-outline.md", "# Talk outline\n\n1. Why local-first\n2. Demo\n3. Questions\n"),
        ]
        var paths: [String: String] = [:]
        for (key, entry) in contents {
            let url = folder.appendingPathComponent(entry.0)
            try? Data(entry.1.utf8).write(to: url)
            paths[key] = url.path
        }
        return paths
    }

    /// Seeds the database. Returns the ids the stages look up by label. A failed step is skipped, not fatal: the
    /// harness reports what it could stage.
    static func seed(database: FlotsamDatabase, settings: SettingsStore, filesFolder: URL, now: Date) async -> Seeded {
        let paths = makeFiles(in: filesFolder)
        let ingest = IngestActor(database: database, settings: settings)

        // Newest first. 40 entries: 14 text, 6 code, 6 links, 4 colours, 4 images, 2 contact, 1 file, 1 bundle, 2 more text.
        let entries: [Entry] = [
            text("note", "Meeting notes: ship the beta on Thursday, freeze scope on Tuesday", notes),
            typed("link1", .link, "https://example.com/docs/getting-started", safari),
            text("code", swiftSnippet, textEdit),
            image("image1", width: 640, height: 400, hue: 0.58, preview),
            text("text1", "Pick up oat milk and lemons on the way home", notes),
            typed("color1", .color, "#E8553D", textEdit),
            text("shortcut", "Thanks for the quick turnaround on the review. Happy to jump on a call if anything is unclear.", textEdit),
            typed("link2", .link, "https://example.org/blog/seasonal-recipes", safari),
            text("code2", "git log --oneline --since=yesterday --author=alex", terminal),
            file("file1", path: paths["report"] ?? ""),
            text("text2", "Grocery list: basil, garlic, olive oil, rigatoni, parmesan", notes),
            text("text3", "Draft subject line: A quieter way to keep your clips", textEdit),
            typed("color2", .color, "#2B6CB0", textEdit),
            image("image2", width: 480, height: 480, hue: 0.08, preview),
            text("code3", "{\n  \"name\": \"sample\",\n  \"version\": \"1.2.0\",\n  \"private\": true\n}", textEdit),
            typed("link3", .link, "https://example.net/maps?q=harbor+lighthouse", safari),
            text("text4", "Ideas for the weekend hike: ridge loop, river trail, lighthouse point", notes),
            typed("email1", .email, "hello@example.com", notes),
            text("text5", "Order 48213 confirmed, arriving Friday between nine and noon", safari),
            bundle("bundle", paths: [paths["budget"] ?? "", paths["outline"] ?? ""]),
            text("code4", "SELECT name, total FROM invoices WHERE paid = 0 ORDER BY total DESC LIMIT 10;", terminal),
            typed("color3", .color, "#38A169", textEdit),
            text("text6", "Call the dentist to move Tuesday's appointment to the afternoon", notes),
            image("image3", width: 800, height: 500, hue: 0.33, preview),
            typed("link4", .link, "https://example.com/changelog", safari),
            text("text7", "Packing list: charger, passport, sunglasses, notebook", notes),
            text("code5", ".card { border-radius: 12px; padding: 16px; background: #f4f1ea; }", textEdit),
            text("text14", "Parking is free after six on the east side of the square", notes),
            text("text8", "Dear team, the offsite agenda is attached. Please add your topics by Friday.", textEdit),
            typed("phone1", .phone, "+1 555 0142", notes),
            text("text9", "Reading list: a short history of type, the design of everyday things", safari),
            typed("link5", .link, "https://example.org/guides/keyboard-shortcuts", safari),
            text("text10", "Birthday idea: a framed map of the old neighborhood", notes),
            typed("color4", .color, "#805AD5", textEdit),
            text("code6", "for item in 1...5 { total += item * 2 }", textEdit),
            image("image4", width: 400, height: 600, hue: 0.83, preview),
            text("text11", "Standup: finished the importer, starting on export tomorrow", notes),
            typed("link6", .link, "https://example.net/status", safari),
            text("text12", "Reminder to water the ferns and rotate the basil", notes),
            text("text13", "Lunch order: miso soup, rice bowl, green tea", notes),
        ]

        var seeded = Seeded()
        // Oldest first, so insertion order matches the timestamps.
        for index in entries.indices.reversed() {
            let entry = entries[index]
            let date = now.addingTimeInterval(-age(at: index))
            guard let candidate = entry.make(date) else { continue }
            if case .success(let result) = await ingest.ingest(candidate) {
                switch result.outcome {
                case .created(let id), .bumped(let id), .unchanged(let id): seeded.ids[entry.label] = id
                }
            }
        }

        // Organise: two pins, two tags, one note, one shortcut (the bundle is ingested as one item).
        let ids = seeded.ids
        if let first = ids["text2"], let second = ids["link1"] { _ = await database.setPinned(ids: [first, second], pinned: true) }
        let work = ["note", "link1", "link4", "text11", "code"].compactMap { ids[$0] }
        if !work.isEmpty { _ = await database.createTagAndApply(name: "Work", color: .blue, to: work) }
        let home = ["text1", "text2", "text4", "text6", "text7"].compactMap { ids[$0] }
        if !home.isEmpty { _ = await database.createTagAndApply(name: "Home", color: .green, to: home) }
        if let noted = ids["note"] {
            _ = await database.setNote("Confirm the date with the whole team before sending", for: noted)
        }
        if let bound = ids["shortcut"] {
            let chord = Chord(keyCode: 38, modifiers: [.command, .option, .control])
            _ = await database.applyExemptionEdit(.setHotkey(chord), to: bound)
            // A real entered trigger, so 08 shows typed text (label colour) rather than the empty field's ";sig" placeholder.
            _ = await database.applyExemptionEdit(.setTrigger(";thx"), to: bound)
        }
        return seeded
    }
}
#endif
