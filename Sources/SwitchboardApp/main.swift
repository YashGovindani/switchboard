import AppKit
import SwiftUI
import SwitchboardCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var panel: OverlayPanel?
    private var activeEnv: String?
    private var opening = 0 {
        didSet { updateStatusIcon() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()

        let menu = NSMenu()
        menu.addItem(withTitle: "Show Switchboard   ⌥Space", action: #selector(toggleOverlay), keyEquivalent: "")
        menu.addItem(withTitle: "Open config file", action: #selector(openConfig), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Switchboard", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu

        hotKey = HotKey.optionSpace { [weak self] in self?.toggleOverlay() }
        if hotKey == nil {
            showError("Could not register ⌥Space — another app may already use it.")
        }

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
        let config = (try? ConfigStore.load()) ?? Config(environments: [])
        let view = OverlayView(
            config: config,
            onOpen: { [weak self] (env: SwitchboardCore.Environment) in self?.openEnvironment(env) },
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
        activeEnv = env.name
        opening += 1

        // First switch triggers the one-time Accessibility prompt; without
        // the grant, focusing degrades to app-level activation.
        WindowTracker.ensureAccessibility()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tracker = WindowTracker.shared

            // Hide the environment we're leaving (fullscreen windows stay
            // parked on their own Spaces and are skipped).
            if let previous, previous != env.name {
                tracker.minimizeNonFullscreen(previous)
            }

            if tracker.focus(env.name) {
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
                to: env.name, since: before, expecting: env.actions.count
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
        _ = try? ConfigStore.load() // ensures the sample exists
        NSWorkspace.shared.open(ConfigStore.configURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
