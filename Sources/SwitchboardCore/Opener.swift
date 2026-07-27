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

    /// Opens an environment: resolves and runs every action. Returns overall success.
    @discardableResult
    public static func open(_ env: Environment, log: ((String) -> Void)? = nil) -> Bool {
        var allOK = true
        for action in env.actions {
            do {
                let cmds = try commands(for: action, in: env.name, log: log)
                if !Runner.run(cmds, label: action.name, log: log) { allOK = false }
            } catch {
                log?("  [\(action.name)] error: \(error)")
                allOK = false
            }
        }
        return allOK
    }
}
