import Foundation

enum ClaudeError: Error, CustomStringConvertible {
    case cliNotFound
    case badExit(Int32, String)
    case unparseableOutput(String)

    var description: String {
        switch self {
        case .cliNotFound:
            return "claude CLI not found in PATH"
        case .badExit(let code, let stderr):
            return "claude exited with code \(code): \(stderr)"
        case .unparseableOutput(let out):
            return "could not parse claude output as a JSON array of commands:\n\(out)"
        }
    }
}

/// Translates a natural-language action prompt into concrete zsh commands
/// using the local `claude` CLI in headless (-p) mode.
enum ClaudeBridge {
    static func generateCommands(for prompt: String) throws -> [String] {
        let instruction = """
        Translate the following intent into macOS zsh shell commands.

        Intent: \(prompt)

        Respond with ONLY a JSON array of strings — one shell command per element, \
        to be executed in order with `zsh -lc`. No markdown fences, no explanations.

        Rules:
        - Commands must not block: launch GUI apps with `open`, use `code` for VS Code, \
        use `osascript` for iTerm/AppleScript control.
        - Prefer a single command when possible.
        - Expand nothing dangerous: no sudo, no rm -rf, no piping remote scripts to shell.
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "claude -p --output-format text " + shellQuote(instruction)]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            if err.contains("command not found") { throw ClaudeError.cliNotFound }
            throw ClaudeError.badExit(process.terminationStatus, err)
        }
        return try parseCommands(from: out)
    }

    /// Accepts a bare JSON array, or one wrapped in markdown fences / prose.
    static func parseCommands(from output: String) throws -> [String] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let commands = decodeArray(trimmed) { return commands }
        // Fall back to the first [...] block in the output.
        if let start = trimmed.firstIndex(of: "["), let end = trimmed.lastIndex(of: "]"), start < end {
            if let commands = decodeArray(String(trimmed[start...end])) { return commands }
        }
        throw ClaudeError.unparseableOutput(trimmed)
    }

    private static func decodeArray(_ text: String) -> [String]? {
        try? JSONDecoder().decode([String].self, from: Data(text.utf8))
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
