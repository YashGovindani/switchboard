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
    public static let url = StoreDir.url.appendingPathComponent("cache.json")

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
        try FileManager.default.createDirectory(at: StoreDir.url, withIntermediateDirectories: true)
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

    /// Drops every cached entry belonging to an environment (used on delete),
    /// including its cleanup namespace.
    public static func removeAll(env: String) {
        var cache = load()
        cache = cache.filter { !$0.key.hasPrefix("\(env)/") && !$0.key.hasPrefix("\(env)#cleanup/") }
        try? save(cache)
    }

    /// Drops a single action's cached entry (used when an action is renamed).
    public static func remove(env: String, action: String) {
        var cache = load()
        cache[key(env: env, action: action)] = nil
        try? save(cache)
    }

    /// Duplicates one namespace's cached commands into another (both the
    /// plain and "#cleanup" variants) — used when saving or instantiating
    /// templates so no re-translation is needed.
    public static func copyNamespace(from old: String, to new: String) {
        var cache = load()
        for (key, value) in load() {
            if key.hasPrefix("\(old)/") {
                cache[new + key.dropFirst(old.count)] = value
            } else if key.hasPrefix("\(old)#cleanup/") {
                cache["\(new)#cleanup" + key.dropFirst("\(old)#cleanup".count)] = value
            }
        }
        try? save(cache)
    }

    /// Rewrites an environment's cache keys after a rename.
    public static func renameEnv(_ old: String, to new: String) {
        let cache = load()
        var updated: [String: CachedAction] = [:]
        for (key, value) in cache {
            if key.hasPrefix("\(old)/") {
                updated[new + key.dropFirst(old.count)] = value
            } else if key.hasPrefix("\(old)#cleanup/") {
                updated["\(new)#cleanup" + key.dropFirst("\(old)#cleanup".count)] = value
            } else {
                updated[key] = value
            }
        }
        try? save(updated)
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
