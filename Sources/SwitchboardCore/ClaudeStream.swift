import Foundation

/// A persistent `claude` CLI process in stream-json mode.
///
/// One session = one conversation: the CLI keeps context between turns, so
/// callers send only the new message. Text deltas are surfaced via `onDelta`
/// for live streaming; `send` returns the turn's final result text.
public final class ClaudeStreamSession {
    public enum SessionError: Error, CustomStringConvertible {
        case timeout
        case processDied(String)

        public var description: String {
            switch self {
            case .timeout: return "claude did not respond in time"
            case .processDied(let detail): return "claude process ended: \(detail)"
            }
        }
    }

    private let queue = DispatchQueue(label: "switchboard.claude-stream")
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrPipe: Pipe?
    private var leftover = Data()

    public init() {}

    deinit { close() }

    public func close() {
        try? stdinHandle?.close()
        process?.terminate()
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrPipe = nil
        leftover = Data()
    }

    /// Sends one user message and blocks until the turn's result event.
    /// `onDelta` receives incremental text as the model streams it.
    public func send(_ text: String, timeout: TimeInterval = 300, onDelta: ((String) -> Void)? = nil) throws -> String {
        try queue.sync {
            try ensureRunning()
            try writeUserMessage(text)
            return try readResult(deadline: Date().addingTimeInterval(timeout), onDelta: onDelta)
        }
    }

    private func ensureRunning() throws {
        if let process, process.isRunning { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [
            "-lc",
            "claude -p --input-format stream-json --output-format stream-json --include-partial-messages --verbose",
        ]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()

        process = p
        stdinHandle = inPipe.fileHandleForWriting
        stdoutHandle = outPipe.fileHandleForReading
        stderrPipe = errPipe
        leftover = Data()
    }

    private func writeUserMessage(_ text: String) throws {
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try stdinHandle?.write(contentsOf: data)
    }

    private func readResult(deadline: Date, onDelta: ((String) -> Void)?) throws -> String {
        while Date() < deadline {
            guard let line = readLine() else {
                let stderr = stderrPipe.map {
                    String(decoding: $0.fileHandleForReading.availableData, as: UTF8.self)
                } ?? ""
                close()
                throw SessionError.processDied(stderr.isEmpty ? "no output" : stderr)
            }
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }

            switch type {
            case "stream_event":
                if let event = object["event"] as? [String: Any],
                   event["type"] as? String == "content_block_delta",
                   let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let piece = delta["text"] as? String {
                    onDelta?(piece)
                }
            case "result":
                if object["is_error"] as? Bool == true {
                    throw SessionError.processDied(object["result"] as? String ?? "unknown error")
                }
                return object["result"] as? String ?? ""
            default:
                break
            }
        }
        close()
        throw SessionError.timeout
    }

    /// Blocking newline-delimited read from the claude process's stdout.
    private func readLine() -> Data? {
        while true {
            if let idx = leftover.firstIndex(of: 0x0A) {
                let line = Data(leftover.prefix(upTo: idx))
                leftover = Data(leftover.suffix(from: leftover.index(after: idx)))
                return line
            }
            guard let chunk = stdoutHandle?.availableData, !chunk.isEmpty else {
                return nil // EOF
            }
            leftover.append(chunk)
        }
    }
}
