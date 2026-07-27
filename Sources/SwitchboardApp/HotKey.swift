import Carbon.HIToolbox
import Foundation

/// Global hotkey via the Carbon RegisterEventHotKey API — works from a
/// background app with no special permissions.
final class HotKey {
    typealias Handler = () -> Void

    private static var handlersByID: [UInt32: Handler] = [:]
    private static var eventHandlerInstalled = false
    private static var nextID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?

    static func optionSpace(_ handler: @escaping Handler) -> HotKey? {
        HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), handler: handler)
    }

    init?(keyCode: UInt32, modifiers: UInt32, handler: @escaping Handler) {
        Self.installEventHandlerIfNeeded()
        let id = Self.nextID
        Self.nextID += 1
        Self.handlersByID[id] = handler

        let hotKeyID = EventHotKeyID(signature: OSType(0x5357_4244), id: id) // 'SWBD'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        hotKeyRef = ref
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            DispatchQueue.main.async { HotKey.handlersByID[hotKeyID.id]?() }
            return noErr
        }, 1, &eventType, nil, nil)
        eventHandlerInstalled = true
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }
}
