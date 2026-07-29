import AppKit
import ApplicationServices
import SwitchboardCore

// Private-but-stable AX call (used by every macOS window manager) that maps
// an AXUIElement window to its CGWindowID — the only reliable bridge between
// the Accessibility API and the CoreGraphics window list.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

struct TrackedWindow: Codable, Hashable {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
}

/// Knows which on-screen windows belong to which environment.
///
/// Attribution is by diffing the CG window list around an environment's
/// actions; focus/minimize goes through the Accessibility API (one-time
/// permission). State persists across app restarts and is validated against
/// the live window list on every use.
final class WindowTracker {
    static let shared = WindowTracker()

    private let lock = NSLock()
    private var windowsByEnv: [String: [TrackedWindow]] = [:]
    private let stateURL = ConfigStore.dir.appendingPathComponent("state.json")

    private init() { load() }

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

    /// Watches for windows that appeared since `before` and records them as
    /// belonging to `env`. Blocks its (background) thread while polling —
    /// apps like Chrome and VS Code take a few seconds to create windows.
    /// `expecting` is the number of windows the environment's actions should
    /// produce (one per action); once reached, polling ends early instead of
    /// waiting out the full deadline. Returns the windows it attributed.
    @discardableResult
    func attributeNewWindows(
        to env: String,
        since before: Set<CGWindowID>,
        expecting: Int = .max,
        pollFor seconds: TimeInterval = 8
    ) -> [TrackedWindow] {
        var discovered: [TrackedWindow] = []
        var policyByPid: [pid_t: Bool] = [:]
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, discovered.count < expecting {
            Thread.sleep(forTimeInterval: 0.5)
            let current = currentWindows()
            let newIDs = Set(current.keys).subtracting(before).subtracting(discovered.map(\.windowID))
            for id in newIDs {
                guard let info = current[id] else { continue }
                guard !Self.ignoredApps.contains(info.appName) else { continue }
                let regular = policyByPid[info.pid] ?? isRegularApp(info.pid)
                policyByPid[info.pid] = regular
                guard regular else { continue }
                discovered.append(TrackedWindow(windowID: id, pid: info.pid, appName: info.appName))
            }
        }
        guard !discovered.isEmpty else { return [] }

        lock.lock()
        let stillLive = liveWindowsLocked(for: env)
        windowsByEnv[env] = stillLive + discovered.filter { !stillLive.contains($0) }
        saveLocked()
        lock.unlock()
        NSLog("switchboard: tracked %d window(s) for '%@'", discovered.count, env)
        return discovered
    }

    /// Puts each window into native fullscreen (its own Space); macOS queues
    /// the Space transitions itself.
    func makeFullscreen(_ windows: [TrackedWindow]) {
        guard AXIsProcessTrusted() else { return }
        for tracked in windows {
            for axWindow in axWindows(of: tracked.pid) {
                var id: CGWindowID = 0
                guard _AXUIElementGetWindow(axWindow, &id) == .success, id == tracked.windowID else { continue }

                var fullscreen: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullscreen)
                if (fullscreen as? Bool) != true {
                    AXUIElementSetAttributeValue(axWindow, "AXFullScreen" as CFString, kCFBooleanTrue)
                }
                break
            }
        }
    }

    // MARK: Queries

    /// Tracked windows of `env` that still exist on screen.
    func liveWindows(for env: String) -> [TrackedWindow] {
        lock.lock()
        defer { lock.unlock() }
        return liveWindowsLocked(for: env)
    }

    private func liveWindowsLocked(for env: String) -> [TrackedWindow] {
        let current = currentWindows()
        return (windowsByEnv[env] ?? []).filter { current[$0.windowID] != nil }
    }

    func forget(env: String) {
        lock.lock()
        windowsByEnv[env] = nil
        saveLocked()
        lock.unlock()
    }

    func rename(env old: String, to new: String) {
        lock.lock()
        if let windows = windowsByEnv.removeValue(forKey: old) {
            windowsByEnv[new] = windows
        }
        saveLocked()
        lock.unlock()
    }

    /// Closes the environment's live windows (presses each AX close button)
    /// and forgets its tracking. Part of "Finish task".
    func closeWindows(of env: String) {
        if AXIsProcessTrusted() {
            for tracked in liveWindows(for: env) {
                for axWindow in axWindows(of: tracked.pid) {
                    var id: CGWindowID = 0
                    guard _AXUIElementGetWindow(axWindow, &id) == .success, id == tracked.windowID else { continue }
                    var button: CFTypeRef?
                    AXUIElementCopyAttributeValue(axWindow, kAXCloseButtonAttribute as CFString, &button)
                    if let button, CFGetTypeID(button) == AXUIElementGetTypeID() {
                        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
                    }
                    break
                }
            }
        }
        forget(env: env)
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
    func focus(_ env: String) -> Bool {
        let live = liveWindows(for: env)
        guard !live.isEmpty else { return false }

        let trusted = AXIsProcessTrusted()
        let byPid = Dictionary(grouping: live, by: \.pid)
        for (pid, windows) in byPid {
            if trusted {
                let targetIDs = Set(windows.map(\.windowID))
                for axWindow in axWindows(of: pid) {
                    var id: CGWindowID = 0
                    guard _AXUIElementGetWindow(axWindow, &id) == .success, targetIDs.contains(id) else { continue }
                    AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                }
            }
            // Bring the app forward either way; without AX this at least
            // surfaces the app's windows.
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
        return true
    }

    /// Minimizes the environment's live windows — except fullscreen ones,
    /// which live on their own Space and are already out of the way.
    func minimizeNonFullscreen(_ env: String) {
        guard AXIsProcessTrusted() else { return }
        let live = liveWindows(for: env)
        let byPid = Dictionary(grouping: live, by: \.pid)
        for (pid, windows) in byPid {
            let targetIDs = Set(windows.map(\.windowID))
            for axWindow in axWindows(of: pid) {
                var id: CGWindowID = 0
                guard _AXUIElementGetWindow(axWindow, &id) == .success, targetIDs.contains(id) else { continue }

                var fullscreen: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString, &fullscreen)
                if (fullscreen as? Bool) == true { continue }

                AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        }
    }

    private func axWindows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        return value as? [AXUIElement] ?? []
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let stored = try? JSONDecoder().decode([String: [TrackedWindow]].self, from: data)
        else { return }
        windowsByEnv = stored
    }

    private func saveLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(windowsByEnv).write(to: stateURL)
    }
}
