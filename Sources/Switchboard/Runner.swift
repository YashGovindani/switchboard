import Foundation

enum Runner {
    /// Runs each command with `zsh -lc`, stopping on the first failure.
    static func run(_ commands: [String], label: String) -> Bool {
        for command in commands {
            print("  [\(label)] $ \(command)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                print("  [\(label)] failed to launch: \(error)")
                return false
            }
            if process.terminationStatus != 0 {
                print("  [\(label)] exited with code \(process.terminationStatus)")
                return false
            }
        }
        return true
    }
}
