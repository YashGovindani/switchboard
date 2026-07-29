import Foundation

public struct Config: Codable {
    public var environments: [Environment]
    /// Global hotkey override; nil means the default (⌥Space).
    public var hotkey: HotKeyConfig?

    public init(environments: [Environment], hotkey: HotKeyConfig? = nil) {
        self.environments = environments
        self.hotkey = hotkey
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

public struct Environment: Codable, Identifiable, Hashable {
    public var name: String
    public var actions: [ActionSpec]
    /// Teardown actions run by "Finish task"; absent in older configs.
    public var cleanup: [ActionSpec]?

    public var id: String { name }

    public init(name: String, actions: [ActionSpec], cleanup: [ActionSpec]? = nil) {
        self.name = name
        self.actions = actions
        self.cleanup = cleanup
    }
}

/// An action is pure intent: a name plus a natural-language prompt.
/// The local `claude` CLI translates the prompt into shell commands,
/// which are cached until the prompt changes.
public struct ActionSpec: Codable, Hashable {
    public var name: String
    public var prompt: String

    public init(name: String, prompt: String) {
        self.name = name
        self.prompt = prompt
    }
}

public enum ConfigStore {
    public static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/switchboard")
    public static let configURL = dir.appendingPathComponent("config.json")

    public static func load() throws -> Config {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try writeSample()
            FileHandle.standardError.write(Data("Created sample config at \(configURL.path)\n".utf8))
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    public static func save(_ config: Config) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(config).write(to: configURL)
    }

    static func writeSample() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sample = """
        {
          "environments": [
            {
              "name": "sample",
              "actions": [
                { "name": "browser",  "prompt": "Open a new Google Chrome window showing https://example.com" },
                { "name": "editor",   "prompt": "Open VS Code at ~/switchboard" },
                { "name": "terminal", "prompt": "Open a new iTerm window, cd to ~/switchboard and print 'Switchboard environment ready'" }
              ]
            }
          ]
        }
        """
        try Data(sample.utf8).write(to: configURL)
    }
}
