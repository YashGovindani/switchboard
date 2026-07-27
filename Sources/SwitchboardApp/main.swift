import AppKit
import SwiftUI
import SwitchboardCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var panel: OverlayPanel?
    private var opening = 0 {
        didSet { updateStatusIcon() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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
        opening += 1
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = Opener.open(env) { NSLog("switchboard: %@", $0) }
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
