import Foundation

public struct Config: Codable {
    public var environments: [Environment]
    /// Reusable action sets: create environments pre-filled from these.
    /// Same shape as an environment (name + actions + cleanup).
    public var templates: [Environment]?
    /// Global hotkey override; nil means the default (⌥Space).
    public var hotkey: HotKeyConfig?

    public init(environments: [Environment], templates: [Environment]? = nil, hotkey: HotKeyConfig? = nil) {
        self.environments = environments
        self.templates = templates
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
    /// Stable identity, independent of the (renamable) name. Generated for
    /// configs written before ids existed and persisted on first load.
    public var id: UUID
    public var name: String
    public var actions: [ActionSpec]
    /// Teardown actions run by "Finish task"; absent in older configs.
    public var cleanup: [ActionSpec]?

    public init(id: UUID = UUID(), name: String, actions: [ActionSpec], cleanup: [ActionSpec]? = nil) {
        self.id = id
        self.name = name
        self.actions = actions
        self.cleanup = cleanup
    }

    private enum CodingKeys: String, CodingKey { case id, name, actions, cleanup }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        actions = try container.decode([ActionSpec].self, forKey: .actions)
        cleanup = try container.decodeIfPresent([ActionSpec].self, forKey: .cleanup)
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
        let config = try JSONDecoder().decode(Config.self, from: data)

        // Older configs carry no ids: the decoder just generated fresh ones,
        // so write them back once to make them permanent.
        struct Probe: Decodable {
            struct Entry: Decodable { let id: UUID? }
            let environments: [Entry]
            let templates: [Entry]?
        }
        if let probe = try? JSONDecoder().decode(Probe.self, from: data),
           (probe.environments + (probe.templates ?? [])).contains(where: { $0.id == nil }) {
            try? save(config)
        }
        return config
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
