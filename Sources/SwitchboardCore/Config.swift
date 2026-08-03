import Foundation

// MARK: - Records
// Every record carries a UUID; cross-references between files use these ids
// (environment → template, action → chat), never names or indexes.

/// An action is pure intent: a name plus a natural-language prompt.
/// The local `claude` CLI translates the prompt into shell commands,
/// which are cached until the prompt changes.
public struct ActionSpec: Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var prompt: String
    /// Links to chats/<chatID>.json — the conversation that designed this action.
    public var chatID: UUID?

    public init(id: UUID = UUID(), name: String, prompt: String, chatID: UUID? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.chatID = chatID
    }

    private enum CodingKeys: String, CodingKey { case id, name, prompt, chatID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decode(String.self, forKey: .prompt)
        chatID = try container.decodeIfPresent(UUID.self, forKey: .chatID)
    }
}

/// A tracked window belonging to an environment (window-server id + owner).
public struct WindowRef: Codable, Hashable {
    public var windowID: UInt32
    public var pid: Int32
    public var appName: String

    public init(windowID: UInt32, pid: Int32, appName: String) {
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
    }
}

/// An environment (or a template — same shape, stored in templates.json).
public struct Environment: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// Template this environment was instantiated from, when any.
    public var templateID: UUID?
    public var actions: [ActionSpec]
    /// Teardown actions run by "Finish task".
    public var cleanup: [ActionSpec]?
    /// Live window records for switching; maintained by the app.
    public var windows: [WindowRef]?

    public init(
        id: UUID = UUID(),
        name: String,
        templateID: UUID? = nil,
        actions: [ActionSpec],
        cleanup: [ActionSpec]? = nil,
        windows: [WindowRef]? = nil
    ) {
        self.id = id
        self.name = name
        self.templateID = templateID
        self.actions = actions
        self.cleanup = cleanup
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey { case id, name, templateID, actions, cleanup, windows }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        templateID = try container.decodeIfPresent(UUID.self, forKey: .templateID)
        actions = try container.decode([ActionSpec].self, forKey: .actions)
        cleanup = try container.decodeIfPresent([ActionSpec].self, forKey: .cleanup)
        windows = try container.decodeIfPresent([WindowRef].self, forKey: .windows)
    }
}

/// A recorded global shortcut (Carbon key code + modifier mask).
public struct HotKeyConfig: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var display: String

    public init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// kVK_Space + optionKey
    public static let optionSpace = HotKeyConfig(keyCode: 49, modifiers: 2048, display: "⌥Space")
}

/// App-wide settings (settings.json).
public struct Settings: Codable {
    /// Global hotkey override; nil means the default (⌥Space).
    public var hotkey: HotKeyConfig?

    public init(hotkey: HotKeyConfig? = nil) {
        self.hotkey = hotkey
    }
}

// MARK: - Chat history

public struct ChatMessage: Codable, Hashable {
    public var role: String // "user" | "assistant"
    public var text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

/// One design conversation (chats/<id>.json); actions link to it by chatID.
/// Edit sessions append to the same record.
public struct ChatRecord: Codable, Identifiable {
    public var id: UUID
    public var messages: [ChatMessage]
    public var updatedAt: Date

    public init(id: UUID, messages: [ChatMessage], updatedAt: Date) {
        self.id = id
        self.messages = messages
        self.updatedAt = updatedAt
    }
}
