import Foundation
import CryptoKit

/// Cached translation of one action's prompt into shell commands.
public struct CachedAction: Codable {
    public var promptHash: String
    public var commands: [String]
    public var generatedAt: Date
}

/// Cache keyed by "<environment>/<action>". A cached entry is valid only
/// while the prompt's hash matches, so editing a prompt regenerates it.
public enum CommandCache {
    public static let url = ConfigStore.dir.appendingPathComponent("cache.json")

    static func hash(of prompt: String) -> String {
        SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func load() -> [String: CachedAction] {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode([String: CachedAction].self, from: data)
        else { return [:] }
        return cache
    }

    static func save(_ cache: [String: CachedAction]) throws {
        try FileManager.default.createDirectory(at: ConfigStore.dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cache).write(to: url)
    }

    static func key(env: String, action: String) -> String { "\(env)/\(action)" }

    public static func lookup(env: String, action: ActionSpec) -> CachedAction? {
        guard let entry = load()[key(env: env, action: action.name)],
              entry.promptHash == hash(of: action.prompt)
        else { return nil }
        return entry
    }

    /// Drops every cached entry belonging to an environment (used on delete).
    public static func removeAll(env: String) {
        var cache = load()
        cache = cache.filter { !$0.key.hasPrefix("\(env)/") }
        try? save(cache)
    }

    public static func store(env: String, action: ActionSpec, commands: [String]) throws {
        var cache = load()
        cache[key(env: env, action: action.name)] = CachedAction(
            promptHash: hash(of: action.prompt),
            commands: commands,
            generatedAt: Date()
        )
        try save(cache)
    }
}
