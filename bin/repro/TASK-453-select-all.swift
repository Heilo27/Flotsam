// TASK-453 reproduction: real CGEvent key events (⌘A, then "x") posted to a process shaped like Flotsam's Library
// edit card: .accessory app, no scenes, non-activating NSPanel, SwiftUI TextEditor bound to a draft.
// Run:  swiftc -o /tmp/repro453 bin/repro/TASK-453-select-all.swift && /tmp/repro453            (as shipped: no main menu)
//       /tmp/repro453 --edit-menu                                                                (with an Edit > Select All item)
// Needs Accessibility trust for the posting process. Expected after ⌘A then "x": draft == "x".
// Observed without a main menu: draft == "hello worldx" (selection stays a 0-length caret). With the menu: "x".
import AppKit
import SwiftUI
import Observation

@Observable @MainActor final class Org { var draft = "hello world" }
struct Card: View {
    let org: Org
    @FocusState var focused: Bool
    var body: some View {
        @Bindable var org = org
        TextEditor(text: $org.draft).focused($focused).frame(width: 300, height: 120).onAppear { focused = true }
    }
}
final class Panel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { false } }

@MainActor func run() {
    let withMenu = CommandLine.arguments.contains("--edit-menu")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if withMenu {
        let main = NSMenu(); let item = NSMenuItem(); main.addItem(item)
        let edit = NSMenu(title: "Edit"); item.submenu = edit
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        app.mainMenu = main
    }
    let org = Org()
    let panel = Panel(contentRect: NSRect(x: 200, y: 200, width: 340, height: 160),
                      styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    panel.isFloatingPanel = true; panel.level = .floating
    panel.contentView = NSHostingView(rootView: Card(org: org))
    // Same shape as LibraryPanelController.handle with an overlay open: nothing but Esc / ⌘Return consumed.
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in e }
    panel.makeKeyAndOrderFront(nil)
    let pid = ProcessInfo.processInfo.processIdentifier
    func post(_ key: CGKeyCode, cmd: Bool = false) {
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
            ev.flags = cmd ? .maskCommand : []
            ev.postToPid(pid)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        func firstText() -> NSTextView? {
            func find(_ v: NSView) -> NSTextView? { if let t = v as? NSTextView { return t }; for s in v.subviews { if let t = find(s) { return t } }; return nil }
            return find(panel.contentView!)
        }
        let tv = firstText()
        print("firstResponder is NSTextView:", panel.firstResponder is NSTextView, " key:", panel.isKeyWindow, " mainMenu:", app.mainMenu != nil)
        // Put caret at end like a fresh edit (draft loaded, focus set)
        tv?.setSelectedRange(NSRange(location: tv?.string.count ?? 0, length: 0))
        post(0, cmd: true)          // ⌘A
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            print("after ⌘A selectedRange:", tv?.selectedRange() as Any)
            post(7)                 // 'x'
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                print("after typing x: draft = \"\(org.draft)\"  nstextview = \"\(tv?.string ?? "")\"")
                exit(0)
            }
        }
    }
    app.run()
}
MainActor.assumeIsolated { run() }
