import SwiftUI
import SwitchboardCore

/// State for one "design an action" conversation with local claude.
/// Backed by a persistent stream-json claude process: the CLI keeps the
/// conversation, so each turn sends only the new message, and replies
/// stream in live via `partial`.
final class ActionChatModel: ObservableObject {
    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        let text: String
    }

    @Published var messages: [Message] = []
    @Published var pending = false
    @Published var partial = ""
    @Published var proposal: ClaudeBridge.ActionProposal?

    private var session = ClaudeStreamSession()
    private var instructionSent = false
    private var pendingContext: String?
    /// The chat record this conversation persists into — every completed turn
    /// is appended immediately, so a crash never loses the discussion.
    private(set) var chatID = UUID()

    func reset() {
        session.close()
        session = ClaudeStreamSession()
        instructionSent = false
        pendingContext = nil
        chatID = UUID()
        messages = []
        pending = false
        partial = ""
        proposal = nil
    }

    /// Extra context (e.g. the existing action being edited) delivered to
    /// claude along with the user's first message.
    func prepare(context: String) {
        pendingContext = context
    }

    /// Continues an existing chat record: shows its stored history and makes
    /// this session's turns append to the same file.
    func adopt(chatID id: UUID) {
        chatID = id
        if let record = ChatStore.load(id) {
            messages = record.messages.map {
                Message(role: $0.role == "user" ? .user : .assistant, text: $0.text)
            }
        }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !pending else { return }
        messages.append(Message(role: .user, text: trimmed))
        pending = true
        partial = ""

        // The instruction (and any edit context) rides along with the first
        // message only; the session keeps the conversation after that.
        let payload: String
        if instructionSent {
            payload = trimmed
        } else {
            let context = pendingContext.map { "\n" + $0 + "\n" } ?? "\n"
            payload = ClaudeBridge.chatInstruction + context + trimmed
            pendingContext = nil
        }
        instructionSent = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.session.send(payload) { piece in
                    DispatchQueue.main.async { self.partial += piece }
                }
                let (reply, proposal) = ClaudeBridge.parseChatReply(result)
                DispatchQueue.main.async {
                    self.messages.append(Message(role: .assistant, text: reply))
                    if let proposal { self.proposal = proposal }
                    self.partial = ""
                    self.pending = false
                    // Persist the turn right away so mid-design work survives
                    // an app crash.
                    ChatStore.append(self.chatID, messages: [
                        SwitchboardCore.ChatMessage(role: "user", text: trimmed),
                        SwitchboardCore.ChatMessage(role: "assistant", text: reply),
                    ])
                }
            } catch {
                DispatchQueue.main.async {
                    self.messages.append(Message(role: .assistant, text: "Error: \(error)"))
                    self.partial = ""
                    self.pending = false
                    ChatStore.append(self.chatID, messages: [
                        SwitchboardCore.ChatMessage(role: "user", text: trimmed),
                        SwitchboardCore.ChatMessage(role: "assistant", text: "Error: \(error)"),
                    ])
                }
            }
        }
    }
}

/// Vertical chat popover for designing an action with claude: discuss until
/// the proposed steps look right, then create the action from them.
struct ActionChatView: View {
    @ObservedObject var model: ActionChatModel
    @State private var input = ""
    @State private var editedName = ""
    let onCreate: (ClaudeBridge.ActionProposal) -> Void

    /// While streaming, hide anything from the start of a fenced block —
    /// the proposal JSON is shown as a card once the turn completes.
    private var visiblePartial: String {
        model.partial.components(separatedBy: "```").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if model.messages.isEmpty {
                            Text("Describe what this action should do — refine it with Claude, then create it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                        ForEach(model.messages) { message in
                            bubble(text: message.text, isUser: message.role == .user)
                                .id(message.id)
                        }
                        if model.pending {
                            if visiblePartial.isEmpty {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Claude is thinking…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                bubble(text: visiblePartial, isUser: false)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(10)
                }
                .onChange(of: model.messages.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.partial) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            if let proposal = model.proposal {
                Divider()
                proposalCard(proposal)
            }

            Divider()

            HStack(spacing: 6) {
                TextField("Message…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .onSubmit(sendInput)
                Button(action: sendInput) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(model.pending || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sendInput() {
        model.send(input)
        input = ""
    }

    @ViewBuilder
    private func bubble(text: String, isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isUser
                            ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                            : AnyShapeStyle(.quaternary.opacity(0.5)))
                )
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private func proposalCard(_ proposal: ClaudeBridge.ActionProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Proposed steps")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(proposal.commands.enumerated()), id: \.offset) { i, command in
                Text("\(i + 1). \(command)")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            HStack(spacing: 6) {
                TextField("Action name", text: $editedName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 140)
                    .onAppear { editedName = proposal.name }
                Spacer()
                Button("Create action") {
                    let name = editedName.trimmingCharacters(in: .whitespaces)
                    onCreate(ClaudeBridge.ActionProposal(
                        name: name.isEmpty ? proposal.name : name,
                        intent: proposal.intent,
                        commands: proposal.commands
                    ))
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3))
    }
}
