import Foundation

struct Config: Codable {
    var environments: [Environment]
}

struct Environment: Codable {
    var name: String
    var actions: [ActionSpec]
}

/// An action is pure intent: a name plus a natural-language prompt.
/// The local `claude` CLI translates the prompt into shell commands,
/// which are cached until the prompt changes.
struct ActionSpec: Codable {
    var name: String
    var prompt: String
}

enum ConfigStore {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/switchboard")
    static let configURL = dir.appendingPathComponent("config.json")

    static func load() throws -> Config {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try writeSample()
            FileHandle.standardError.write(Data("Created sample config at \(configURL.path)\n".utf8))
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(Config.self, from: data)
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
