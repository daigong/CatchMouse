import AppKit

/// Wires together the display manager, global hotkeys, the menu-bar UI and the
/// Preferences window, and keeps the hotkeys in sync as displays change or the
/// user edits their shortcuts.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let displays = DisplayManager()
    private let hotKeys = HotKeyCenter()
    private let store = HotKeyStore.shared
    private let openPreferencesOnLaunch: Bool
    private var menu: StatusMenuController!
    /// Last active application other than CatchMouse. A menu-bar menu does not
    /// necessarily become the frontmost app, but the Preferences window can,
    /// so menu-triggered actions fall back to this.
    private var lastActivePid: pid_t?
    private lazy var preferences = PreferencesWindowController(displays: displays, store: store) { [weak self] in
        self?.reload()
    }

    init(openPreferencesOnLaunch: Bool = false) {
        self.openPreferencesOnLaunch = openPreferencesOnLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        CursorPulse.restoreStaleScale()
        displays.onCursorMoved = { CursorPulse.show() }
        menu = StatusMenuController(displays: displays, store: store) { [weak self] action in
            self?.perform(action)
        }
        reload()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let frontmost = NSWorkspace.shared.frontmostApplication
        lastActivePid = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? nil
            : frontmost?.processIdentifier
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if openPreferencesOnLaunch { preferences.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        CursorPulse.cancel()
    }

    @objc private func screensChanged() { reload() }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        lastActivePid = app.processIdentifier
    }

    /// Re-register hotkeys and rebuild the menu to match the current displays
    /// and the user's stored shortcuts.
    private func reload() {
        registerHotKeys()
        menu.rebuild()
    }

    private func perform(_ action: MenuAction) {
        switch action {
        case .moveTo(let index):
            let ids = displays.orderedDisplays()
            if ids.indices.contains(index) { displays.moveCursor(to: ids[index]) }
        case .next:
            displays.moveToAdjacentDisplay(forward: true)
        case .previous:
            displays.moveToAdjacentDisplay(forward: false)
        case .maximize:
            maximizeFrontWindow()
        case .fullScreen:
            toggleFullScreen()
        case .golden:
            goldenResize()
        case .openPreferences:
            preferences.show()
        case .identifyDisplays:
            DisplayIdentifier.flash(displays: displays)
        }
    }

    private func registerHotKeys() {
        hotKeys.unregisterAll()

        // Per-display jump keys (user binding, or positional default).
        for (index, id) in displays.orderedDisplays().enumerated() {
            let key = displays.stableKey(for: id)
            guard let combo = Shortcuts.jumpCombo(index: index, displayKey: key, store: store) else { continue }
            hotKeys.register(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) { [weak self] in
                guard let self, let target = self.displays.display(forStableKey: key) else { return }
                self.displays.moveCursor(to: target)
            }
        }

        // Cycle keys.
        let next = Shortcuts.nextCombo(store)
        hotKeys.register(keyCode: next.keyCode, modifiers: next.carbonModifiers) { [weak self] in
            self?.displays.moveToAdjacentDisplay(forward: true)
        }
        let prev = Shortcuts.prevCombo(store)
        hotKeys.register(keyCode: prev.keyCode, modifiers: prev.carbonModifiers) { [weak self] in
            self?.displays.moveToAdjacentDisplay(forward: false)
        }

        let maximize = Shortcuts.maximizeCombo(store)
        hotKeys.register(keyCode: maximize.keyCode, modifiers: maximize.carbonModifiers) { [weak self] in
            self?.perform(.maximize)
        }

        let fullScreen = Shortcuts.fullScreenCombo(store)
        hotKeys.register(keyCode: fullScreen.keyCode, modifiers: fullScreen.carbonModifiers) { [weak self] in
            self?.perform(.fullScreen)
        }

        let golden = Shortcuts.goldenCombo(store)
        hotKeys.register(keyCode: golden.keyCode, modifiers: golden.carbonModifiers) { [weak self] in
            self?.perform(.golden)
        }
    }

    private var targetPid: pid_t? {
        NSWorkspace.shared.frontmostApplication.flatMap { app -> pid_t? in
            app.processIdentifier == ProcessInfo.processInfo.processIdentifier
                ? nil
                : app.processIdentifier
        } ?? lastActivePid
    }

    private func maximizeFrontWindow() {
        handleWindowAction(WindowMaximizer.maximize(pid: targetPid))
    }

    private func toggleFullScreen() {
        handleWindowAction(WindowMaximizer.toggleFullScreen(pid: targetPid))
    }

    private func goldenResize() {
        handleWindowAction(WindowMaximizer.goldenResize(pid: targetPid))
    }

    private func handleWindowAction(_ succeeded: Bool) {
        guard !succeeded else { return }
        if !WindowMaximizer.isTrusted {
            WindowMaximizer.requestAccess()
        } else {
            NSSound.beep()
        }
    }
}
