import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var hider: MenuBarHider!
    private var contextMenu: NSMenu!
    private var autoHideTimer: Timer?
    private var healthCheckTimer: Timer?

    private enum Setting {
        static let autoHide = "AutoHideAfterReveal"
        static let autoHideDelay = 15.0
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        hider = MenuBarHider()
        hider.onStateChange = { [weak self] in self?.stateDidChange() }

        buildMenu()
        configureArrowButton()
        observeMenuBarChanges()
        observeExternalToggle()

        // The whole point of the app: start out of the way.
        hider.hide()
    }

    private func configureArrowButton() {
        guard let button = hider.arrowButton else { return }
        button.target = self
        button.action = #selector(arrowClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateArrowIcon()
    }

    private func updateArrowIcon() {
        guard let button = hider.arrowButton else { return }
        // Points towards the icons: left while they are tucked away, right to
        // put them back.
        let symbol = hider.isHidden ? "chevron.left" : "chevron.right"
        let description = hider.isHidden ? "Show menu bar icons" : "Hide menu bar icons"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.toolTip = description
    }

    private func stateDidChange() {
        updateArrowIcon()
        scheduleAutoHideIfNeeded()
    }

    // MARK: - Clicks

    @objc private func arrowClicked() {
        let event = NSApp.currentEvent
        let isSecondaryClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isSecondaryClick {
            presentContextMenu()
        } else {
            hider.toggle()
        }
    }

    /// `NSStatusItem.menu` steals the primary click, so the menu is attached
    /// only for the duration of one right-click and detached in `menuDidClose`.
    private func presentContextMenu() {
        contextMenu.items.first?.title = hider.isHidden ? "Show Icons" : "Hide Icons"
        hider.arrowStatusItem.menu = contextMenu
        hider.arrowButton?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        hider.arrowStatusItem.menu = nil
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(withTitle: "Show Icons", action: #selector(toggleFromMenu), keyEquivalent: "")

        menu.addItem(.separator())

        let autoHide = NSMenuItem(title: "Hide Again After \(Int(Setting.autoHideDelay))s",
                                  action: #selector(toggleAutoHide),
                                  keyEquivalent: "")
        autoHide.state = isAutoHideEnabled ? .on : .off
        menu.addItem(autoHide)

        let loginItem = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleLaunchAtLogin),
                                   keyEquivalent: "")
        menu.addItem(loginItem)

        menu.addItem(withTitle: "Keep One More Icon Visible",
                     action: #selector(keepMoreVisible), keyEquivalent: "")
        menu.addItem(withTitle: "Keep One Fewer Icon Visible",
                     action: #selector(keepFewerVisible), keyEquivalent: "")

        menu.addItem(.separator())

        let chevron = NSMenuItem(title: "Hide macOS Chevron Too",
                                 action: #selector(toggleSystemChevron),
                                 keyEquivalent: "")
        chevron.toolTip = "Push the expander far enough to swallow macOS's own «."
        menu.addItem(chevron)

        menu.addItem(withTitle: "Reset Icon Position",
                     action: #selector(resetPosition), keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit JustHide", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items where item.action != nil {
            item.target = self
        }
        contextMenu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Login item state can change behind our back in System Settings.
        Log.debug("login item status: \(LoginItem.statusDescription); bundle: \(Bundle.main.bundlePath)")
        menu.item(withTitle: "Launch at Login")?.state = LoginItem.isRegistered ? .on : .off
        menu.item(withTitle: "Hide macOS Chevron Too")?.state = hider.hidesSystemChevron ? .on : .off
    }

    @objc private func toggleFromMenu() { hider.toggle() }

    @objc private func toggleAutoHide(_ sender: NSMenuItem) {
        let enabled = !isAutoHideEnabled
        UserDefaults.standard.set(enabled, forKey: Setting.autoHide)
        sender.state = enabled ? .on : .off
        scheduleAutoHideIfNeeded()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let wanted = !LoginItem.isRegistered
        if let problem = LoginItem.setEnabled(wanted) {
            let alert = NSAlert()
            alert.messageText = wanted ? "Launch at login needs one more step"
                                       : "Could not disable launch at login"
            alert.informativeText = problem
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        Log.debug("login item now: \(LoginItem.statusDescription)")
        sender.state = LoginItem.isRegistered ? .on : .off
    }

    @objc private func keepMoreVisible() {
        Task { @MainActor in await hider.moveSeparator(keepingMore: true) }
    }

    @objc private func keepFewerVisible() {
        Task { @MainActor in await hider.moveSeparator(keepingMore: false) }
    }

    @objc private func toggleSystemChevron(_ sender: NSMenuItem) {
        hider.hidesSystemChevron.toggle()
        sender.state = hider.hidesSystemChevron ? .on : .off
        hider.revalidate(force: true)
    }

    /// For when a ⌘-drag has left the arrow on the wrong side of the expander,
    /// where hiding would swallow it.
    @objc private func resetPosition() {
        Task { @MainActor in await hider.resetPosition() }
    }

    @objc private func quit() {
        // Leave the menu bar the way we found it.
        hider.show()
        NSApp.terminate(nil)
    }

    // MARK: - Auto hide

    private var isAutoHideEnabled: Bool {
        UserDefaults.standard.bool(forKey: Setting.autoHide)
    }

    private func scheduleAutoHideIfNeeded() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        guard isAutoHideEnabled, !hider.isHidden else { return }
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: Setting.autoHideDelay,
                                             repeats: false) { _ in
            Task { @MainActor in
                // Never yank the bar shut under the pointer: the user is most
                // likely on their way to one of the icons they just revealed.
                guard !Self.pointerIsInMenuBar else {
                    self.scheduleAutoHideIfNeeded()
                    return
                }
                self.hider.hide()
            }
        }
    }

    private static var pointerIsInMenuBar: Bool {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            screen.frame.contains(point) && point.y > screen.visibleFrame.maxY
        }
    }

    /// Lets anything on the machine flip the icons without clicking — bind a
    /// hotkey to:
    ///
    ///     osascript -e 'do shell script ""' # (any launcher works)
    ///     notifyutil / Shortcuts / Raycast → post com.jhyti.justhide.toggle
    private func observeExternalToggle() {
        let center = DistributedNotificationCenter.default()
        for (name, action) in [("toggle", Action.toggle), ("show", .show), ("hide", .hide)] {
            center.addObserver(forName: Notification.Name("com.jhyti.justhide.\(name)"),
                               object: nil, queue: .main) { _ in
                Task { @MainActor in self.perform(action) }
            }
        }
    }

    private enum Action { case toggle, show, hide }

    private func perform(_ action: Action) {
        switch action {
        case .toggle: hider.toggle()
        case .show: hider.show()
        case .hide: hider.hide()
        }
    }

    // MARK: - Keeping the expander honest

    /// The usable width of the status area changes whenever the front app's
    /// menus change width, a display is added, or another app adds an icon —
    /// all of which can either free up room (icons creep back into view) or
    /// take it away (the expander gets dropped and everything reappears).
    private func observeMenuBarChanges() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { _ in Task { @MainActor in self.hider.revalidate(force: true) } }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in Task { @MainActor in self.hider.revalidate(force: true) } }

        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in
                guard self.hider.needsRecalibration else { return }
                self.hider.revalidate(force: false)
            }
        }
    }
}
