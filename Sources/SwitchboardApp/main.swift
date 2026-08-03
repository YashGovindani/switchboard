import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import SwitchboardCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var panel: OverlayPanel?
    private var activeEnv: UUID?
    private var showMenuItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?
    private var recorderWindow: NSWindow?
    private var recorderMonitor: Any?
    private var opening = 0 {
        didSet { updateStatusIcon() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Migration.run()
        installEditMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()

        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Switchboard", action: #selector(toggleOverlay), keyEquivalent: "")
        menu.addItem(show)
        showMenuItem = show
        menu.addItem(withTitle: "Change Shortcut…", action: #selector(changeShortcut), keyEquivalent: "")
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        loginMenuItem = login
        menu.addItem(withTitle: "Open config file", action: #selector(openConfig), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Switchboard", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        applyHotKey(SettingsStore.load().hotkey ?? .optionSpace)

        NotificationCenter.default.addObserver(
            forName: .switchboardPanelResize, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let panel = self.panel,
                  let width = notification.userInfo?["width"] as? Double,
                  let height = notification.userInfo?["height"] as? Double
            else { return }
            let old = panel.frame
            let newFrame = NSRect(
                x: old.midX - width / 2,
                y: old.maxY - height,
                width: width,
                height: height
            )
            // Matches the SwiftUI easeInOut(0.28) on chatOpen so the panel
            // and its content animate as one.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        }
    }

    @objc private func toggleOverlay() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        showOverlay()
    }

    private func showOverlay() {
        let view = OverlayView(
            environments: EnvironmentStore.load(),
            templates: TemplateStore.load(),
            onOpen: { [weak self] (env: SwitchboardCore.Environment) in self?.openEnvironment(env) },
            onFinish: { [weak self] (env: SwitchboardCore.Environment) in self?.finishEnvironment(env) },
            onDismiss: { [weak self] in self?.panel?.orderOut(nil) }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        hosting.autoresizingMask = [.width, .height]

        let panel = OverlayPanel(contentView: hosting, size: hosting.frame.size)
        self.panel = panel
        panel.showCentered()
    }

    private func openEnvironment(_ env: SwitchboardCore.Environment) {
        let previous = activeEnv
        activeEnv = env.id
        opening += 1

        // First switch triggers the one-time Accessibility prompt; without
        // the grant, focusing degrades to app-level activation.
        WindowTracker.ensureAccessibility()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tracker = WindowTracker.shared

            // Hide the environment we're leaving (fullscreen windows stay
            // parked on their own Spaces and are skipped).
            if let previous, previous != env.id {
                tracker.minimizeNonFullscreen(previous)
            }

            if tracker.focus(env.id) {
                // Already open — focused its windows instead of re-running.
                DispatchQueue.main.async { self?.opening -= 1 }
                return
            }

            // Nothing left of this environment: run its actions, learn which
            // windows they created, and take each one fullscreen (its own
            // Space) per the fullscreen-first workflow.
            let before = tracker.snapshot()
            let ok = Opener.open(env) { NSLog("switchboard: %@", $0) }
            let created = tracker.attributeNewWindows(
                to: env.id, since: before, expecting: env.actions.count
            )
            tracker.makeFullscreen(created)

            DispatchQueue.main.async {
                self?.opening -= 1
                if !ok {
                    self?.showError("Some actions of '\(env.name)' failed. See Console logs or run `switchboard open \(env.name)` in a terminal for details.")
                }
            }
        }
    }

    /// "Finish task": run the environment's cleanup actions, then close its
    /// tracked windows and forget them.
    private func finishEnvironment(_ env: SwitchboardCore.Environment) {
        opening += 1
        WindowTracker.ensureAccessibility()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = Opener.finish(env) { NSLog("switchboard: %@", $0) }
            WindowTracker.shared.closeWindows(of: env.id)
            DispatchQueue.main.async {
                if self?.activeEnv == env.id { self?.activeEnv = nil }
                self?.opening -= 1
                if !ok {
                    self?.showError("Some cleanup actions of '\(env.name)' failed. Run `switchboard finish \(env.name)` in a terminal for details.")
                }
            }
        }
    }

    // MARK: Hotkey

    private func applyHotKey(_ config: HotKeyConfig) {
        hotKey = nil // unregisters the previous one
        hotKey = HotKey(keyCode: config.keyCode, modifiers: config.modifiers) { [weak self] in
            self?.toggleOverlay()
        }
        showMenuItem?.title = "Show Switchboard   \(config.display)"
        if hotKey == nil {
            showError("Could not register \(config.display) — another app may already use it.")
        }
    }

    @objc private func changeShortcut() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Switchboard Shortcut"
        window.level = .floating
        window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Press the new shortcut\n(needs ⌘, ⌥ or ⌃ — Esc cancels)")
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 30, width: 300, height: 50)
        window.contentView?.addSubview(label)
        window.center()
        recorderWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape
                self.closeRecorder()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
                return nil // ignore unmodified keys; keep recording
            }
            let config = HotKeyConfig(
                keyCode: UInt32(event.keyCode),
                modifiers: Self.carbonModifiers(flags),
                display: Self.shortcutDisplay(flags: flags, event: event)
            )
            self.closeRecorder()
            self.applyHotKey(config)
            var settings = SettingsStore.load()
            settings.hotkey = config
            SettingsStore.save(settings)
            return nil
        }
    }

    private func closeRecorder() {
        if let recorderMonitor { NSEvent.removeMonitor(recorderMonitor) }
        recorderMonitor = nil
        recorderWindow?.orderOut(nil)
        recorderWindow = nil
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    private static func shortcutDisplay(flags: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var parts = ""
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        let key: String
        switch Int(event.keyCode) {
        case kVK_Space: key = "Space"
        case kVK_Return: key = "Return"
        case kVK_Tab: key = "Tab"
        default: key = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
        return parts + key
    }

    // MARK: Login item

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showError("Could not update the login item: \(error.localizedDescription)")
        }
        loginMenuItem?.state = service.status == .enabled ? .on : .off
    }

    private func updateStatusIcon() {
        let symbol = opening > 0 ? "hourglass" : "rectangle.3.group"
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Switchboard"
        )
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Switchboard"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// A background app has no menu bar, but ⌘C/⌘V/⌘X/⌘A only work when an
    /// Edit menu with those key equivalents exists — so install one invisibly.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        NSApp.mainMenu = mainMenu
    }

    @objc private func openConfig() {
        Migration.run() // ensures the stores exist
        NSWorkspace.shared.open(StoreDir.url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
