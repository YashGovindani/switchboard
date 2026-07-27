import Foundation

public enum Runner {
    /// Runs each command with `zsh -lc`, stopping on the first failure.
    public static func run(_ commands: [String], label: String, log: ((String) -> Void)? = nil) -> Bool {
        let log = log ?? { print($0) }
        for command in commands {
            log("  [\(label)] $ \(command)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                log("  [\(label)] failed to launch: \(error)")
                return false
            }
            if process.terminationStatus != 0 {
                log("  [\(label)] exited with code \(process.terminationStatus)")
                return false
            }
        }
        return true
    }
}
