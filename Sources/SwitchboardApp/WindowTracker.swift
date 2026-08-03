import AppKit
import ApplicationServices
import SwitchboardCore

// Private-but-stable AX call (used by every macOS window manager) that maps
// an AXUIElement window to its CGWindowID — the only reliable bridge between
// the Accessibility API and the CoreGraphics window list.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

/// Knows which on-screen windows belong to which environment.
///
/// Attribution is by diffing the CG window list around an environment's
/// actions; focus/minimize goes through the Accessibility API (one-time
/// permission). Window records live on the environment records themselves
/// (environments.json, via EnvironmentStore), keyed by the environment's id.
final class WindowTracker {
    static let shared = WindowTracker()

    private init() {}

    // MARK: Window list

    /// All normal (layer 0) windows, including ones on other Spaces.
    private func currentWindows() -> [CGWindowID: (pid: pid_t, appName: String)] {
        let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []

        var result: [CGWindowID: (pid: pid_t, appName: String)] = [:]
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int
            else { continue }
            let name = info[kCGWindowOwnerName as String] as? String ?? ""
            result[CGWindowID(number)] = (pid_t(pid), name)
        }
        return result
    }

    func snapshot() -> Set<CGWindowID> {
        Set(currentWindows().keys)
    }

    // MARK: Attribution

    /// System surfaces that must never be attributed to an environment, even
    /// though they can appear during the attribution window (e.g. the user
    /// granting the Accessibility permission mid-open).
    private static let ignoredApps: Set<String> = [
        "System Settings", "Privacy & Security", "Dock", "Finder",
        "Notification Center", "Control Center", "Spotlight", "Switchboard",
    ]

    /// True for ordinary user-facing apps (excludes prompts, XPC helper
    /// windows, and background agents).
    private func isRegularApp(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
    }

    /// Watches for windows that appeared since `before` and records them on
    /// the environment record. Blocks its (background) thread while polling —
    /// apps like Chrome and VS Code take a few seconds to create windows.
    /// `expecting` is the number of windows the environment's actions should
    /// produce (one per action); once reached, polling ends early instead of
    /// waiting out the full deadline. Returns the windows it attributed.
    @discardableResult
    func attributeNewWindows(
        to envID: UUID,
        since before: Set<CGWindowID>,
        expecting: Int = .max,
        pollFor seconds: TimeInterval = 8
    ) -> [SwitchboardCore.WindowRef] {
        var discovered: [SwitchboardCore.WindowRef] = []
        var policyByPid: [pid_t: Bool] = [:]
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, discovered.count < expecting {
            Thread.sleep(forTimeInterval: 0.5)
            let current = currentWindows()
            let newIDs = Set(current.keys).subtracting(before)
                .subtracting(discovered.map { CGWindowID($0.windowID) })
            for id in newIDs {
                guard let info = current[id] else { continue }
                guard !Self.ignoredApps.contains(info.appName) else { continue }
                let regular = policyByPid[info.pid] ?? isRegularApp(info.pid)
                policyByPid[info.pid] = regular
                guard regular else { continue }
                discovered.append(SwitchboardCore.WindowRef(windowID: UInt32(id), pid: Int32(info.pid), appName: info.appName))
            }
        }
        guard !discovered.isEmpty else { return [] }

        EnvironmentStore.update(envID) { env in
            let live = self.filterLive(env.windows)
            env.windows = live + discovered.filter { !live.contains($0) }
        }
        NSLog("switchboard: tracked %d window(s) for env %@", discovered.count, envID.uuidString)
        return discovered
    }

    // MARK: Queries

    /// The environment's tracked windows that still exist on screen.
    func liveWindows(for envID: UUID) -> [SwitchboardCore.WindowRef] {
        filterLive(EnvironmentStore.find(envID)?.windows)
    }

    private func filterLive(_ refs: [SwitchboardCore.WindowRef]?) -> [SwitchboardCore.WindowRef] {
        guard let refs, !refs.isEmpty else { return [] }
        let current = currentWindows()
        return refs.filter { current[CGWindowID($0.windowID)] != nil }
    }

    // MARK: Sweeping

    /// Silently drops window records that no longer exist (e.g. after a
    /// reboot) without treating it as a user-closed transition — so stale
    /// state never triggers auto-cleanup.
    func pruneAll() {
        let current = currentWindows()
        for env in EnvironmentStore.load() {
            guard let windows = env.windows, !windows.isEmpty else { continue }
            let live = windows.filter { current[CGWindowID($0.windowID)] != nil }
            if live.count != windows.count {
                EnvironmentStore.update(env.id) { $0.windows = live.isEmpty ? nil : live }
            }
        }
    }

    /// Environments whose tracked windows have all just disappeared (i.e.
    /// the user closed them). Clears their window records and returns them
    /// so the app can finish them. Partially-closed environments only get
    /// their dead entries pruned.
    func sweepClosed(skipping busy: Set<UUID>) -> [SwitchboardCore.Environment] {
        let current = currentWindows()
        var closed: [SwitchboardCore.Environment] = []
        for env in EnvironmentStore.load() {
            guard !busy.contains(env.id),
                  let windows = env.windows, !windows.isEmpty else { continue }
            let live = windows.filter { current[CGWindowID($0.windowID)] != nil }
            if live.isEmpty {
                EnvironmentStore.update(env.id) { $0.windows = nil }
                closed.append(env)
            } else if live.count != windows.count {
                EnvironmentStore.update(env.id) { $0.windows = live }
            }
        }
        return closed
    }

    // MARK: Accessibility actions

    /// Prompts for the Accessibility permission if not yet granted.
    /// Returns whether the app is currently trusted.
    @discardableResult
    static func ensureAccessibility(promptIfNeeded: Bool = true) -> Bool {
        if AXIsProcessTrusted() { return true }
        if promptIfNeeded {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        return false
    }

    /// Raises and focuses the environment's live windows. Returns false when
    /// there is nothing to focus (caller should run the actions instead).
    func focus(_ envID: UUID) -> Bool {
        let live = liveWindows(for: envID)
        guard !live.isEmpty else { return false }

        let trusted = AXIsProcessTrusted()
        let byPid = Dictionary(grouping: live, by: \.pid)
        for (pid, windows) in byPid {
            if trusted {
                let targetIDs = Set(windows.map { CGWindowID($0.windowID) })
                for axWindow in axWindows(of: pid_t(pid)) {
                    var id: CGWindowID = 0
                    guard _AXUIElementGetWindow(axWindow, &id) == .success, targetIDs.contains(id) else { continue }
                    AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                }
            }
            // Bring the app forward either way; without AX this at least
            // surfaces the app's windows.
            NSRunningApplication(processIdentifier: pid_t(pid))?.activate(options: [])
        }
        return true
    }

    /// Minimizes the environment's live windows — except fullscreen ones,
    /// which live on their own Space and are already out of the way.
    func minimizeNonFullscreen(_ envID: UUID) {
        guard AXIsProcessTrusted() else { return }
        let live = liveWindows(for: envID)
        let byPid = Dictionary(grouping: live, by: \.pid)
        for (pid, windows) in byPid {
            let targetIDs = Set(windows.map { CGWindowID($0.windowID) })
            for axWindow in axWindows(of: pid_t(pid)) {
                var id: CGWindowID = 0
                guard _AXUIElementGetWindow(axWindow, &id) == .success, targetIDs.contains(id) else { continue }

                var fullscreen: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullscreen)
                if (fullscreen as? Bool) == true { continue }

                AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        }
    }

    /// Puts each window into native fullscreen (its own Space); macOS queues
    /// the Space transitions itself.
    func makeFullscreen(_ windows: [SwitchboardCore.WindowRef]) {
        guard AXIsProcessTrusted() else { return }
        for tracked in windows {
            for axWindow in axWindows(of: pid_t(tracked.pid)) {
                var id: CGWindowID = 0
                guard _AXUIElementGetWindow(axWindow, &id) == .success, id == CGWindowID(tracked.windowID) else { continue }

                var fullscreen: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullscreen)
                if (fullscreen as? Bool) != true {
                    AXUIElementSetAttributeValue(axWindow, "AXFullScreen" as CFString, kCFBooleanTrue)
                }
                break
            }
        }
    }

    /// Closes the environment's live windows (presses each AX close button)
    /// and clears its window records. Part of "Finish task".
    func closeWindows(of envID: UUID) {
        if AXIsProcessTrusted() {
            for tracked in liveWindows(for: envID) {
                for axWindow in axWindows(of: pid_t(tracked.pid)) {
                    var id: CGWindowID = 0
                    guard _AXUIElementGetWindow(axWindow, &id) == .success, id == CGWindowID(tracked.windowID) else { continue }
                    var button: CFTypeRef?
                    AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &button)
                    if let button, CFGetTypeID(button) == AXUIElementGetTypeID() {
                        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
                    }
                    break
                }
            }
        }
        EnvironmentStore.update(envID) { $0.windows = nil }
    }

    private func axWindows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }
}
