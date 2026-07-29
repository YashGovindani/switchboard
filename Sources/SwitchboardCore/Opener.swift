import Foundation

/// Shared engine entry point: turns an environment's action prompts into
/// commands (via cache or claude) and executes them.
public enum Opener {
    /// Returns the commands for an action, generating and caching them if needed.
    public static func commands(
        for action: ActionSpec,
        in envName: String,
        force: Bool = false,
        log: ((String) -> Void)? = nil
    ) throws -> [String] {
        if !force, let cached = CommandCache.lookup(env: envName, action: action) {
            return cached.commands
        }
        log?("  [\(action.name)] asking claude to translate prompt…")
        let generated = try ClaudeBridge.generateCommands(for: action.prompt)
        try CommandCache.store(env: envName, action: action, commands: generated)
        return generated
    }

    /// Cache namespace for an environment's cleanup actions, kept separate so
    /// cleanup and regular actions may share names.
    public static func cleanupCacheEnv(_ env: String) -> String { env + "#cleanup" }

    /// Resolves and runs a list of actions against a cache namespace.
    @discardableResult
    public static func run(_ actions: [ActionSpec], cacheEnv: String, log: ((String) -> Void)? = nil) -> Bool {
        var allOK = true
        for action in actions {
            do {
                let cmds = try commands(for: action, in: cacheEnv, log: log)
                if !Runner.run(cmds, label: action.name, log: log) { allOK = false }
            } catch {
                log?("  [\(action.name)] error: \(error)")
                allOK = false
            }
        }
        return allOK
    }

    /// Opens an environment: resolves and runs every action. Returns overall success.
    @discardableResult
    public static func open(_ env: Environment, log: ((String) -> Void)? = nil) -> Bool {
        run(env.actions, cacheEnv: env.name, log: log)
    }

    /// Runs an environment's cleanup actions (if any).
    @discardableResult
    public static func finish(_ env: Environment, log: ((String) -> Void)? = nil) -> Bool {
        run(env.cleanup ?? [], cacheEnv: cleanupCacheEnv(env.name), log: log)
    }
}
