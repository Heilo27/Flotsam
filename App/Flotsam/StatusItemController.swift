import AppKit
import FlotsamBase
import FlotsamStorage

/// The menu-bar item and its menu (FR-008-16). Both are drawn from `MenuBarModel`, which holds the order, the
/// chord rows and the Pause/Resume rule; this class only turns that model into AppKit objects. The menu is rebuilt
/// each time it opens (`menuNeedsUpdate`), so chords and capture mode are never stale.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let container: AppContainer
    private let showSetupGuide: @MainActor () -> Void
    private let item: NSStatusItem
    private var unsubscribe: (@Sendable () -> Void)?

    /// The status item's frame in screen coordinates, for the Shelf's menu-bar placement (FR-006-05c).
    var iconFrame: CGRect? { item.button?.window?.frame }

    init(container: AppContainer, showSetupGuide: @escaping @MainActor () -> Void) {
        self.container = container
        self.showSetupGuide = showSetupGuide
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // AppKit logs "makeKeyWindow called on _NSGlassEffectWindow which returned NO from canBecomeKeyWindow" each time
        // a status-item menu opens (its glass-backed window cannot become key). It is not the Shelf: the Shelf panel
        // never logs it, and Apple's own menu-bar extras log the same line. Harmless; nothing here can silence it.
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refreshIcon()
        container.menuBarIconFrame = { [weak self] in self?.iconFrame }
        container.presenter.onNoticesChanged = { [weak self] in self?.refreshIcon() }
        container.onTriggerStatusChange = { [weak self] in self?.refreshIcon() }
        unsubscribe = container.settings.subscribe { [weak self] _ in
            Task { @MainActor in self?.refreshIcon() }
        }
    }

    deinit { unsubscribe?() }

    // MARK: Icon

    private var icon: MenuIcon {
        MenuBarModel.icon(
            mode: container.settings.value(SettingKeys.captureMode), hasWarning: container.presenter.hasBadge || container.showsTriggerWarning)
    }

    private func refreshIcon() {
        let icon = icon
        guard let button = item.button else { return }
        button.image = MenuBarIcon.image(for: icon)
        // Shape tells the states apart; VoiceOver gets the same information in words (FR-008-17).
        button.setAccessibilityLabel(icon.accessibilityKeys.compactMap { FlotsamStrings.text(forKey: $0) }.joined(separator: ", "))
        button.setAccessibilityTitle(FlotsamStrings.text(forKey: "ui.menu.title"))
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in MenuBarModel.entries(settings: container.settings) {
            switch entry {
            case .openLibrary(let chord): menu.addItem(row("ui.menu.openLibrary", chord: chord, run: container.actions.openLibrary))
            case .saveClipboard(let chord): menu.addItem(row("ui.menu.saveClipboard", chord: chord, run: container.actions.saveClipboard))
            case .addClip(let chord): menu.addItem(row("ui.menu.addClip", chord: chord, run: container.actions.addClip))
            case .toggleShelf(let chord): menu.addItem(row("ui.menu.toggleShelf", chord: chord, run: container.actions.toggleShelf))
            case .separator: menu.addItem(.separator())
            case .captureToggle(let titleKey, let next):
                menu.addItem(row(titleKey, run: { [container] in container.settings.set(next, for: SettingKeys.captureMode) }))
            case .pauseFor: menu.addItem(pauseForItem())
            case .clearRecent: menu.addItem(clearRecentItem())
            case .notices: menu.addItem(noticesItem())
            case .settings: menu.addItem(row("ui.menu.settings", key: ",", run: container.actions.openSettings))
            case .setupGuide: menu.addItem(row("ui.menu.setupGuide", run: showSetupGuide))
            case .quit: menu.addItem(row("ui.menu.quit", key: "q", run: { NSApplication.shared.terminate(nil) }))
            }
        }
    }

    /// Pause For submenu (FR-007-12, FR-008-16): each choice pauses capture and sets when it ends.
    private func pauseForItem() -> NSMenuItem {
        let parent = NSMenuItem(title: FlotsamStrings.text(forKey: "ui.menu.pauseFor") ?? "", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for duration in PauseDuration.allCases {
            submenu.addItem(row(duration.titleKey, run: { [container] in container.timedPause.pause(for: duration) }))
        }
        parent.submenu = submenu
        return parent
    }

    /// Clear Recent submenu (FR-007-11, FR-008-16): each choice opens the confirmation; nothing is deleted from the menu itself.
    private func clearRecentItem() -> NSMenuItem {
        let parent = NSMenuItem(title: FlotsamStrings.text(forKey: "ui.menu.clearRecent") ?? "", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for range in ClearRange.recentMenuRanges {
            let entry = NSMenuItem(title: range.label.text, action: nil, keyEquivalent: "")
            entry.target = self
            entry.action = #selector(fire(_:))
            entry.representedObject = ActionBox { [container] in container.clearRecent(range) }
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    /// Notices submenu (FRD-000 section 9, FR-000-08 b): newest first, the code after the message, then "Dismiss all".
    private func noticesItem() -> NSMenuItem {
        let parent = NSMenuItem(title: FlotsamStrings.text(forKey: "ui.menu.notices") ?? "", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let notices = container.presenter.notices
        if notices.isEmpty {
            let empty = NSMenuItem(title: FlotsamStrings.text(forKey: "ui.menu.noNotices") ?? "", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for notice in notices {
                let line = NSMenuItem(title: "\(notice.message) · \(notice.code.rawValue)", action: nil, keyEquivalent: "")
                line.isEnabled = false
                submenu.addItem(line)
            }
            submenu.addItem(.separator())
            let reporter = container.reporter
            submenu.addItem(row("ui.menu.dismissAll", run: { Task { await reporter.dismissAllNotices() } }))
        }
        parent.submenu = submenu
        return parent
    }

    /// A row that shows its chord as the key equivalent, so it follows the user's binding and reads in the system
    /// style. A nil `run` (the owning feature has not plugged in) leaves the row disabled.
    private func row(_ titleKey: String, chord: ChordBinding, run: (@MainActor () -> Void)?) -> NSMenuItem {
        switch chord {
        case .none: return row(titleKey, run: run)
        case .chord(let value):
            let entry = row(titleKey, key: value.keyEquivalent ?? "", run: run)
            entry.keyEquivalentModifierMask = Self.modifierMask(value.modifiers)
            return entry
        }
    }

    private func row(_ titleKey: String, key: String = "", run: (@MainActor () -> Void)?) -> NSMenuItem {
        let entry = NSMenuItem(title: FlotsamStrings.text(forKey: titleKey) ?? "", action: nil, keyEquivalent: key)
        if let run {
            entry.target = self
            entry.action = #selector(fire(_:))
            entry.representedObject = ActionBox(run)
            entry.isEnabled = true
        } else {
            entry.isEnabled = false
        }
        return entry
    }

    @objc private func fire(_ sender: NSMenuItem) {
        (sender.representedObject as? ActionBox)?.run()
    }

    private static func modifierMask(_ modifiers: ChordModifiers) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        return mask
    }
}

private final class ActionBox: NSObject {
    let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
}
