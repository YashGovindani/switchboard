import SwiftUI
import SwitchboardCore

extension Notification.Name {
    static let switchboardPanelResize = Notification.Name("switchboard.panelResize")
}

/// Root overlay content: environment list, or the new-environment form.
struct OverlayView: View {
    @State private var config: Config
    @State private var creating = false
    @State private var editingEnv: String?
    @State private var chatOpen = false
    @State private var errorMessage: String?

    let onOpen: (SwitchboardCore.Environment) -> Void
    let onDismiss: () -> Void

    init(config: Config, onOpen: @escaping (SwitchboardCore.Environment) -> Void, onDismiss: @escaping () -> Void) {
        _config = State(initialValue: config)
        self.onOpen = onOpen
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if creating {
                NewEnvironmentView(
                    chatOpen: $chatOpen,
                    initialName: editingEnv,
                    onCreate: { name in
                        if let existing = config.environments.first(where: { $0.name == name }) {
                            return existing.actions
                        }
                        config.environments.append(SwitchboardCore.Environment(name: name, actions: []))
                        persist()
                        return []
                    },
                    onSaveAction: { envName, action, commands, replacing in
                        guard let i = config.environments.firstIndex(where: { $0.name == envName }) else { return }
                        if let replacing,
                           let j = config.environments[i].actions.firstIndex(where: { $0.name == replacing }) {
                            config.environments[i].actions[j] = action
                        } else {
                            config.environments[i].actions.append(action)
                        }
                        persist()
                        // The chat already produced the commands — cache them so
                        // opening the environment never needs a re-translation.
                        try? CommandCache.store(env: envName, action: action, commands: commands)
                    },
                    onRemoveAction: { envName, actionName in
                        guard let i = config.environments.firstIndex(where: { $0.name == envName }) else { return }
                        config.environments[i].actions.removeAll { $0.name == actionName }
                        persist()
                    }
                )
            } else {
                listView
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: chatOpen ? 940 : 560, height: chatOpen ? 600 : 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
        .onChange(of: chatOpen) { open in
            NotificationCenter.default.post(
                name: .switchboardPanelResize,
                object: nil,
                userInfo: ["width": open ? 940.0 : 560.0, "height": open ? 600.0 : 420.0]
            )
        }
    }

    /// Always-visible top bar: back chevron while creating, otherwise the
    /// New Environment button.
    private var header: some View {
        HStack(spacing: 8) {
            if creating {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        creating = false
                        chatOpen = false
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Back to environments")
            }
            Image(systemName: "rectangle.3.group")
            Text("Switchboard").font(.headline)
            Spacer()
            if !creating {
                Button {
                    editingEnv = nil
                    creating = true
                } label: {
                    Label("New Environment", systemImage: "plus")
                }
            }
        }
        .padding(14)
    }

    private var listView: some View {
        VStack(spacing: 0) {
            if config.environments.isEmpty {
                Spacer()
                Text("No environments yet — create one.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(config.environments) { env in
                            EnvironmentRow(
                                env: env,
                                action: {
                                    onOpen(env)
                                    onDismiss()
                                },
                                onEdit: {
                                    editingEnv = env.name
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                        creating = true
                                    }
                                },
                                onDelete: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                        config.environments.removeAll { $0.name == env.name }
                                    }
                                    persist()
                                    CommandCache.removeAll(env: env.name)
                                }
                            )
                        }
                    }
                    .padding(10)
                }
            }
        }
    }

    private func persist() {
        do {
            try ConfigStore.save(config)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save config: \(error.localizedDescription)"
        }
    }
}

/// Trash button with an inline two-step confirm: first click shows a red
/// "Sure?" for a few seconds, second click actually deletes.
struct ConfirmDeleteButton: View {
    let help: String
    let onDelete: () -> Void
    @State private var confirming = false

    var body: some View {
        Button {
            if confirming {
                confirming = false
                onDelete()
            } else {
                withAnimation { confirming = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { confirming = false }
                }
            }
        } label: {
            if confirming {
                Label("Sure?", systemImage: "trash.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(confirming ? "Click again to delete" : help)
    }
}

struct EnvironmentRow: View {
    let env: SwitchboardCore.Environment
    let action: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(env.name).font(.system(size: 14, weight: .medium))
                        Text(env.actions.map(\.name).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .foregroundStyle(hovering ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help("Edit environment")

            ConfirmDeleteButton(help: "Delete environment", onDelete: onDelete)

            Button(action: action) {
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(hovering ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help("Open environment")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.accentColor.opacity(0.15) : .clear)
        )
        .onHover { hovering = $0 }
    }
}

/// Two-stage flow for creating an environment:
/// 1. A single centered name field (Next inside the field; Enter works too).
/// 2. The name animates to the top-left; "Add action" sits on the same line,
///    with the list of added actions (name + description) below.
struct NewEnvironmentView: View {
    struct DraftAction: Identifiable {
        let id = UUID()
        var name: String
        var prompt: String
    }

    private enum Stage {
        case askName, building
    }

    @State private var stage: Stage
    @State private var name: String
    @State private var actions: [DraftAction] = []
    @State private var editingActionName: String?
    @Binding var chatOpen: Bool
    @StateObject private var chat = ActionChatModel()
    @FocusState private var nameFocused: Bool
    @Namespace private var animation

    /// Called when the name step is confirmed; creates/persists the environment
    /// immediately and returns any actions it already has.
    let onCreate: (String) -> [ActionSpec]
    /// Called for every action agreed in the chat; persists the action and its
    /// ready-made commands immediately. The last argument is the name of the
    /// action being replaced when this is an edit, or nil for a new action.
    let onSaveAction: (String, ActionSpec, [String], String?) -> Void
    let onRemoveAction: (String, String) -> Void

    init(
        chatOpen: Binding<Bool>,
        initialName: String? = nil,
        onCreate: @escaping (String) -> [ActionSpec],
        onSaveAction: @escaping (String, ActionSpec, [String], String?) -> Void,
        onRemoveAction: @escaping (String, String) -> Void
    ) {
        _chatOpen = chatOpen
        _stage = State(initialValue: initialName == nil ? .askName : .building)
        _name = State(initialValue: initialName ?? "")
        self.onCreate = onCreate
        self.onSaveAction = onSaveAction
        self.onRemoveAction = onRemoveAction
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        switch stage {
        case .askName: askNameView
        case .building: buildingView
        }
    }

    // MARK: Stage 1 — just the name

    private var askNameView: some View {
        VStack(spacing: 0) {
            Spacer()
            TextField("Environment name", text: $name)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($nameFocused)
                .onSubmit(advance)
                .padding(.vertical, 10)
                .padding(.leading, 14)
                .padding(.trailing, 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
                .overlay(alignment: .trailing) {
                    Button(action: advance) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title2)
                            .foregroundStyle(trimmedName.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .disabled(trimmedName.isEmpty)
                }
                .matchedGeometryEffect(id: "envName", in: animation)
                .frame(width: 340)
            Spacer()
        }
        .onAppear { nameFocused = true }
    }

    private func advance() {
        guard !trimmedName.isEmpty else { return }
        let existing = onCreate(trimmedName)
        actions = existing.map { DraftAction(name: $0.name, prompt: $0.prompt) }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            stage = .building
        }
    }

    // MARK: Stage 2 — name top-left, add action right, list below,
    // chat as a full-height right pane while designing an action.

    private var buildingView: some View {
        HStack(spacing: 0) {
            leftColumn

            if chatOpen {
                Divider()
                chatPane
                    .frame(width: 380)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onAppear {
            // Entering via "edit environment": load its existing actions.
            if stage == .building && actions.isEmpty {
                actions = onCreate(trimmedName).map { DraftAction(name: $0.name, prompt: $0.prompt) }
            }
        }
    }

    private var leftColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text(trimmedName)
                    .font(.headline)
                    .matchedGeometryEffect(id: "envName", in: animation)
                Spacer()
                Button {
                    // A leftover edit conversation shouldn't leak into a new action.
                    if editingActionName != nil {
                        editingActionName = nil
                        chat.reset()
                    }
                    withAnimation(.easeInOut(duration: 0.28)) {
                        chatOpen = true
                    }
                } label: {
                    Label("Add action", systemImage: "plus")
                }
                .disabled(chatOpen)
            }
            .padding(14)

            Divider()

            if actions.isEmpty {
                Spacer()
                Text("No actions yet — add one.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(actions) { action in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.name).font(.system(size: 13, weight: .medium))
                                    Text(action.prompt)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Button {
                                    startEditing(action)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Edit this action with Claude")
                                ConfirmDeleteButton(help: "Delete action") {
                                    withAnimation(.easeInOut(duration: 0.28)) {
                                        actions.removeAll { $0.id == action.id }
                                    }
                                    onRemoveAction(trimmedName, action.name)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                        }
                    }
                    .padding(10)
                }
            }

        }
    }

    private var chatPane: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
                Text(editingActionName.map { "Edit '\($0)'" } ?? "Design action with Claude")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        chatOpen = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close chat (conversation is kept)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ActionChatView(model: chat) { proposal in
                let spec = ActionSpec(name: proposal.name, prompt: proposal.intent)
                let replacing = editingActionName
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if let replacing, let i = actions.firstIndex(where: { $0.name == replacing }) {
                        actions[i] = DraftAction(name: spec.name, prompt: spec.prompt)
                    } else {
                        actions.append(DraftAction(name: spec.name, prompt: spec.prompt))
                    }
                    chatOpen = false
                }
                onSaveAction(trimmedName, spec, proposal.commands, replacing)
                editingActionName = nil
                chat.reset()
            }
        }
    }

    /// Opens the chat primed with the action's current definition so the
    /// conversation starts from its existing intent and commands.
    private func startEditing(_ action: DraftAction) {
        editingActionName = action.name
        chat.reset()

        let spec = ActionSpec(name: action.name, prompt: action.prompt)
        let cached = CommandCache.lookup(env: trimmedName, action: spec)
        var context = """
        The user is EDITING an existing action rather than creating a new one.
        Current action name: \(action.name)
        Current intent: \(action.prompt)
        """
        if let cached {
            context += "\nCurrent commands:\n" + cached.commands.map { "  $ \($0)" }.joined(separator: "\n")
        }
        context += "\nApply the user's requested changes to this action and propose the revised version."
        chat.prepare(context: context)

        withAnimation(.easeInOut(duration: 0.28)) {
            chatOpen = true
        }
    }

}
