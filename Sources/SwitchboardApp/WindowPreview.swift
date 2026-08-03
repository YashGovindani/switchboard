import AppKit
import ScreenCaptureKit
import SwiftUI
import SwitchboardCore

/// Captures thumbnails of each environment's live windows for the list view.
/// Uses ScreenCaptureKit (Screen Recording permission) for real window
/// content; until that's granted, falls back to the owning app's icon.
@MainActor
final class PreviewLoader: ObservableObject {
    /// Live windows per environment id, snapshotted when the panel opens.
    @Published var live: [UUID: [SwitchboardCore.WindowRef]] = [:]
    /// Thumbnail (or fallback app icon) per window id.
    @Published var thumbnails: [UInt32: NSImage] = [:]

    func refresh(_ environments: [SwitchboardCore.Environment]) {
        var map: [UUID: [SwitchboardCore.WindowRef]] = [:]
        for env in environments {
            let refs = WindowTracker.shared.liveWindows(for: env.id)
            if !refs.isEmpty { map[env.id] = refs }
        }
        live = map

        let allRefs = map.values.flatMap { $0 }
        guard !allRefs.isEmpty else { return }

        // App icons show immediately; real captures replace them as they land.
        for ref in allRefs where thumbnails[ref.windowID] == nil {
            if let icon = NSRunningApplication(processIdentifier: pid_t(ref.pid))?.icon {
                thumbnails[ref.windowID] = icon
            }
        }

        guard #available(macOS 14.0, *) else { return }
        guard CGPreflightScreenCaptureAccess() else {
            // One-time system prompt; grant applies from the next capture on.
            CGRequestScreenCaptureAccess()
            return
        }

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let targets = Set(allRefs.map { CGWindowID($0.windowID) })
                for scWindow in content.windows where targets.contains(scWindow.windowID) {
                    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                    let configuration = SCStreamConfiguration()
                    let scale = min(1, 360 / max(scWindow.frame.width, 1))
                    configuration.width = max(Int(scWindow.frame.width * scale), 1)
                    configuration.height = max(Int(scWindow.frame.height * scale), 1)
                    configuration.showsCursor = false
                    if let image = try? await SCScreenshotManager.captureImage(
                        contentFilter: filter, configuration: configuration
                    ) {
                        thumbnails[UInt32(scWindow.windowID)] = NSImage(
                            cgImage: image,
                            size: NSSize(width: image.width, height: image.height)
                        )
                    }
                }
            } catch {
                NSLog("switchboard: window preview capture failed: %@", "\(error)")
            }
        }
    }
}

/// A fixed-size box showing an environment's live windows as a square-ish
/// grid: 1×1 for one window, 2×2 up to four, 3×3 up to nine, and so on.
struct WindowPreviewBox: View {
    let refs: [SwitchboardCore.WindowRef]
    let thumbnails: [UInt32: NSImage]

    static let boxWidth: CGFloat = 122
    static let boxHeight: CGFloat = 86

    private var columnCount: Int {
        max(1, Int(ceil(sqrt(Double(refs.count)))))
    }

    private var rowCount: Int {
        max(1, Int(ceil(Double(refs.count) / Double(columnCount))))
    }

    var body: some View {
        Group {
            if refs.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.quaternary)
                    .overlay(
                        Text("closed")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    )
            } else {
                let spacing: CGFloat = 2
                let inset: CGFloat = 3
                let cellHeight = (Self.boxHeight - inset * 2 - spacing * CGFloat(rowCount - 1)) / CGFloat(rowCount)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount),
                    spacing: spacing
                ) {
                    ForEach(refs, id: \.windowID) { ref in
                        ZStack {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.quaternary.opacity(0.5))
                            if let image = thumbnails[ref.windowID] {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            }
                        }
                        .frame(height: cellHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                .padding(inset)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
            }
        }
        .frame(width: Self.boxWidth, height: Self.boxHeight)
        .clipped()
    }
}
