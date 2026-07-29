import Foundation
import SwitchboardCore

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() {
    print("""
    switchboard — AI-configured environment switcher

    Usage:
      switchboard list                     List configured environments
      switchboard open <env>               Open an environment (generates & caches commands on first run)
      switchboard finish <env>             Run an environment's cleanup actions
      switchboard show <env>               Show the cached commands for an environment
      switchboard refresh <env> [action]   Regenerate commands from prompts (all actions, or one)

    Config: ~/.config/switchboard/config.json
    Cache:  ~/.config/switchboard/cache.json
    """)
}

func findEnvironment(_ name: String, in config: Config) -> Environment? {
    config.environments.first { $0.name == name }
}

do {
    let config = try ConfigStore.load()

    switch arguments.first {
    case "list":
        for env in config.environments {
            print("\(env.name)  (\(env.actions.count) actions)")
        }

    case "open":
        guard arguments.count == 2 else { usage(); exit(1) }
        guard let env = findEnvironment(arguments[1], in: config) else {
            print("No environment named '\(arguments[1])'. Run `switchboard list`.")
            exit(1)
        }
        print("Opening environment '\(env.name)'…")
        let allOK = Opener.open(env) { print($0) }
        print(allOK ? "Done." : "Done, with errors.")
        exit(allOK ? 0 : 1)

    case "finish":
        guard arguments.count == 2 else { usage(); exit(1) }
        guard let env = findEnvironment(arguments[1], in: config) else {
            print("No environment named '\(arguments[1])'.")
            exit(1)
        }
        guard let cleanup = env.cleanup, !cleanup.isEmpty else {
            print("'\(env.name)' has no cleanup actions configured.")
            exit(0)
        }
        print("Finishing '\(env.name)'…")
        let ok = Opener.finish(env) { print($0) }
        print(ok ? "Done. (Window closing happens via the app.)" : "Done, with errors.")
        exit(ok ? 0 : 1)

    case "show":
        guard arguments.count == 2 else { usage(); exit(1) }
        guard let env = findEnvironment(arguments[1], in: config) else {
            print("No environment named '\(arguments[1])'.")
            exit(1)
        }
        for action in env.actions {
            print("\(action.name): \(action.prompt)")
            if let cached = CommandCache.lookup(env: env.name, action: action) {
                for cmd in cached.commands { print("    $ \(cmd)") }
            } else {
                print("    (not generated yet — run `switchboard open \(env.name)`)")
            }
        }
        if let cleanup = env.cleanup, !cleanup.isEmpty {
            print("cleanup:")
            for action in cleanup {
                print("  \(action.name): \(action.prompt)")
                if let cached = CommandCache.lookup(env: Opener.cleanupCacheEnv(env.name), action: action) {
                    for cmd in cached.commands { print("      $ \(cmd)") }
                }
            }
        }

    case "refresh":
        guard arguments.count >= 2 else { usage(); exit(1) }
        guard let env = findEnvironment(arguments[1], in: config) else {
            print("No environment named '\(arguments[1])'.")
            exit(1)
        }
        let only = arguments.count > 2 ? arguments[2] : nil
        for action in env.actions where only == nil || action.name == only {
            let cmds = try Opener.commands(for: action, in: env.name, force: true) { print($0) }
            print("  [\(action.name)] regenerated \(cmds.count) command(s)")
        }

    default:
        usage()
    }
} catch {
    print("Error: \(error)")
    exit(1)
}
