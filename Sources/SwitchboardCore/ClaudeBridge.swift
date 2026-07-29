import Foundation

public enum ClaudeError: Error, CustomStringConvertible {
    case cliNotFound
    case badExit(Int32, String)
    case unparseableOutput(String)

    public var description: String {
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
public enum ClaudeBridge {
    public static func generateCommands(for prompt: String) throws -> [String] {
        let instruction = """
        Translate the following intent into macOS zsh shell commands.

        Intent: \(prompt)

        Respond with ONLY a JSON array of strings — one shell command per element, \
        to be executed in order with `zsh -lc`. No markdown fences, no explanations.

        Rules:
        - Commands must not block: launch GUI apps with `open`, use `code` for VS Code, \
        use `osascript` for iTerm/AppleScript control.
        - Every command that opens an app MUST open a NEW window dedicated to this action — \
        never reuse or focus an existing window. Examples: `code --new-window <path>`, \
        `open -na "Google Chrome" --args --new-window <urls...>`, iTerm via \
        `create window with default profile`.
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

    // MARK: Interactive action design

    public struct ActionProposal: Codable {
        public let name: String
        public let intent: String
        public let commands: [String]

        public init(name: String, intent: String, commands: [String]) {
            self.name = name
            self.intent = intent
            self.commands = commands
        }
    }

    /// Instruction sent as the first message of an action-design chat session.
    /// The session (a persistent `claude` process) keeps the conversation, so
    /// this is sent once; later turns are just the user's messages.
    public static let chatInstruction = """
    You are the action designer inside Switchboard, a macOS environment-switcher app. \
    The user is defining ONE action: a short sequence of zsh commands (run with `zsh -lc`) \
    that sets up part of their work environment (windows, apps, servers, containers, …).

    Discuss briefly with the user until the requirement is clear. As soon as it is clear \
    enough, propose concrete steps — don't over-question; one clarifying question at most \
    before proposing. The user may then ask for changes; refine the proposal accordingly. \
    Every message after this one is the same user continuing this conversation.

    Reply in short, plain conversational text. When (and only when) you have a complete \
    concrete proposal — including refined versions — end your reply with exactly one \
    fenced block in this shape:

    ```json
    {"name": "<short-name>", "intent": "<one-sentence description>", "commands": ["<zsh command>", "..."]}
    ```

    Rules for commands: non-blocking (launch GUI apps with `open`, `code` for VS Code, \
    `osascript` for iTerm control), no sudo, no rm -rf, no piping remote scripts to shell. \
    Every command that opens an app MUST open a NEW window dedicated to this action — never \
    reuse or focus an existing window. Examples: `code --new-window <path>`, \
    `open -na "Google Chrome" --args --new-window <urls...>`, iTerm via \
    `create window with default profile`. \
    Do not use any tools; just answer.

    The user's first message follows:
    """

    /// Splits a chat reply into its conversational text and the proposal
    /// carried in a ```json fenced block, if present.
    public static func parseChatReply(_ text: String) -> (reply: String, proposal: ActionProposal?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fenceStart = trimmed.range(of: "```json"),
              let fenceEnd = trimmed.range(of: "```", range: fenceStart.upperBound..<trimmed.endIndex)
        else { return (trimmed, nil) }

        let jsonText = String(trimmed[fenceStart.upperBound..<fenceEnd.lowerBound])
        let prose = (String(trimmed[..<fenceStart.lowerBound]) + String(trimmed[fenceEnd.upperBound...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let proposal = try? JSONDecoder().decode(ActionProposal.self, from: Data(jsonText.utf8)) else {
            return (trimmed, nil)
        }
        return (prose.isEmpty ? "Here's my proposal:" : prose, proposal)
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
