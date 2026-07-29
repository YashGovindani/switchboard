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
    @State private var builderName: String?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var addActionRequest = 0
    @State private var chatOpen = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var searchFocused: Bool

    let onOpen: (SwitchboardCore.Environment) -> Void
    let onFinish: (SwitchboardCore.Environment) -> Void
    let onDismiss: () -> Void

    init(
        config: Config,
        onOpen: @escaping (SwitchboardCore.Environment) -> Void,
        onFinish: @escaping (SwitchboardCore.Environment) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _config = State(initialValue: config)
        self.onOpen = onOpen
        self.onFinish = onFinish
        self.onDismiss = onDismiss
    }

    private var filtered: [SwitchboardCore.Environment] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return config.environments }
        return config.environments.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if creating {
                builder
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
        .frame(width: chatOpen ? 1020 : 560, height: chatOpen ? 620 : 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
        .onChange(of: chatOpen) { open in
            NotificationCenter.default.post(
                name: .switchboardPanelResize,
                object: nil,
                userInfo: ["width": open ? 1020.0 : 560.0, "height": open ? 620.0 : 420.0]
            )
        }
    }

    private var builder: some View {
        NewEnvironmentView(
            chatOpen: $chatOpen,
            initialName: editingEnv,
            addActionRequest: addActionRequest,
            onNameConfirmed: { name in
                withAnimation(.easeInOut(duration: 0.28)) { builderName = name }
                editingEnv = name
            },
            onCreate: { name in
                if let existing = config.environments.first(where: { $0.name == name }) {
                    return existing
                }
                let fresh = SwitchboardCore.Environment(name: name, actions: [])
                config.environments.append(fresh)
                persist()
                return fresh
            },
            onSaveAction: { envName, action, commands, replacing, isCleanup in
                guard let i = config.environments.firstIndex(where: { $0.name == envName }) else { return }
                if isCleanup {
                    var cleanup = config.environments[i].cleanup ?? []
                    if let replacing, let j = cleanup.firstIndex(where: { $0.name == replacing }) {
                        cleanup[j] = action
                    } else {
                        cleanup.append(action)
                    }
                    config.environments[i].cleanup = cleanup
                } else if let replacing,
                          let j = config.environments[i].actions.firstIndex(where: { $0.name == replacing }) {
                    config.environments[i].actions[j] = action
                } else {
                    config.environments[i].actions.append(action)
                }
                persist()
                // The chat already produced the commands — cache them so
                // opening/finishing never needs a re-translation.
                let cacheEnv = isCleanup ? Opener.cleanupCacheEnv(envName) : envName
                try? CommandCache.store(env: cacheEnv, action: action, commands: commands)
            },
            onRemoveAction: { envName, actionName, isCleanup in
                guard let i = config.environments.firstIndex(where: { $0.name == envName }) else { return }
                if isCleanup {
                    config.environments[i].cleanup?.removeAll { $0.name == actionName }
                } else {
                    config.environments[i].actions.removeAll { $0.name == actionName }
                }
                persist()
            }
        )
        .id(editingEnv)
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
                        builderName = nil
                        renaming = false
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Back to environments")
            }
            Image(systemName: "rectangle.3.group")
            if creating, renaming {
                TextField("Environment name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(commitRename)
                Button {
                    renaming = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel rename")
            } else {
                Text(creating ? (builderName ?? "New Environment") : "Switchboard")
                    .font(.headline)
                if creating, let builderName {
                    Button {
                        renameText = builderName
                        renaming = true
                    } label: {
                        Image(systemName: "pencil").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Rename environment")
                }
            }
            Spacer()
            if creating {
                if builderName != nil {
                    Button {
                        addActionRequest += 1
                    } label: {
                        Label("Add action", systemImage: "plus")
                    }
                    .disabled(chatOpen)
                }
            } else {
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

    private func commitRename() {
        let new = renameText.trimmingCharacters(in: .whitespaces)
        guard let old = builderName, !new.isEmpty, new != old else {
            renaming = false
            return
        }
        guard !config.environments.contains(where: { $0.name == new }) else {
            errorMessage = "An environment named '\(new)' already exists."
            return
        }
        guard let i = config.environments.firstIndex(where: { $0.name == old }) else {
            renaming = false
            return
        }
        config.environments[i].name = new
        persist()
        CommandCache.renameEnv(old, to: new)
        WindowTracker.shared.rename(env: old, to: new)
        builderName = new
        editingEnv = new // new view identity reloads the builder under the new name
        renaming = false
    }

    private var listView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search environments…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        guard filtered.indices.contains(selected) else { return }
                        let env = filtered[selected]
                        onOpen(env)
                        onDismiss()
                    }
                    .onMoveCommand { direction in
                        switch direction {
                        case .down: selected = min(selected + 1, max(filtered.count - 1, 0))
                        case .up: selected = max(selected - 1, 0)
                        default: break
                        }
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .onAppear { searchFocused = true }
            .onChange(of: query) { _ in selected = 0 }

            Divider()

            if filtered.isEmpty {
                Spacer()
                Text(config.environments.isEmpty ? "No environments yet — create one." : "No match.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, env in
                                EnvironmentRow(
                                    env: env,
                                    isSelected: index == selected,
                                    action: {
                                        onOpen(env)
                                        onDismiss()
                                    },
                                    onFinish: {
                                        onFinish(env)
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
                                        WindowTracker.shared.forget(env: env.name)
                                    }
                                )
                                .id(index)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: selected) { index in
                        withAnimation { proxy.scrollTo(index) }
                    }
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

/// Copies the given text to the clipboard, flashing a checkmark as feedback.
struct CopyButton: View {
    let text: String
    let help: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied!" : help)
    }
}

/// Icon button with an inline two-step confirm: first click shows a colored
/// confirmation label for a few seconds, second click performs the action.
struct ConfirmActionButton: View {
    var idleIcon = "trash"
    var confirmIcon = "trash.fill"
    var confirmText = "Sure?"
    var tint: Color = .red
    let help: String
    let action: () -> Void
    @State private var confirming = false

    var body: some View {
        Button {
            if confirming {
                confirming = false
                action()
            } else {
                withAnimation { confirming = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { confirming = false }
                }
            }
        } label: {
            if confirming {
                Label(confirmText, systemImage: confirmIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            } else {
                Image(systemName: idleIcon)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(confirming ? "Click again to confirm" : help)
    }
}

struct EnvironmentRow: View {
    let env: SwitchboardCore.Environment
    let isSelected: Bool
    let action: () -> Void
    let onFinish: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

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

            ConfirmActionButton(
                idleIcon: "stop.circle",
                confirmIcon: "stop.circle.fill",
                confirmText: "End?",
                tint: .orange,
                help: "Finish task: run cleanup actions and close this environment's windows",
                action: onFinish
            )

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .foregroundStyle(hovering ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help("Edit environment")

            ConfirmActionButton(help: "Delete environment", action: onDelete)

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
                .fill(isSelected || hovering ? Color.accentColor.opacity(0.15) : .clear)
        )
        .onHover { hovering = $0 }
    }
}

/// Two-stage flow for creating an environment:
/// 1. A single centered name field (Next inside the field; Enter works too).
/// 2. Action and cleanup lists, with the chat as a full-height right pane
///    while designing an action.
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
    @State private var cleanups: [DraftAction] = []
    @State private var editingActionName: String?
    @State private var designingCleanup = false
    @Binding var chatOpen: Bool
    @StateObject private var chat = ActionChatModel()
    @FocusState private var nameFocused: Bool

    /// Incremented by the header's Add action button; observed to open the chat.
    let addActionRequest: Int
    /// Called once the environment's name is known (name step confirmed, or
    /// entering via edit) so the header can display it.
    let onNameConfirmed: (String) -> Void
    /// Called when the name step is confirmed; creates/persists the environment
    /// immediately and returns it (with any existing actions).
    let onCreate: (String) -> SwitchboardCore.Environment
    /// Persists an agreed action and its ready-made commands immediately.
    /// `replacing` names the action being replaced on edit; `isCleanup`
    /// routes to the cleanup list.
    let onSaveAction: (String, ActionSpec, [String], String?, Bool) -> Void
    let onRemoveAction: (String, String, Bool) -> Void

    init(
        chatOpen: Binding<Bool>,
        initialName: String? = nil,
        addActionRequest: Int = 0,
        onNameConfirmed: @escaping (String) -> Void,
        onCreate: @escaping (String) -> SwitchboardCore.Environment,
        onSaveAction: @escaping (String, ActionSpec, [String], String?, Bool) -> Void,
        onRemoveAction: @escaping (String, String, Bool) -> Void
    ) {
        _chatOpen = chatOpen
        _stage = State(initialValue: initialName == nil ? .askName : .building)
        _name = State(initialValue: initialName ?? "")
        self.addActionRequest = addActionRequest
        self.onNameConfirmed = onNameConfirmed
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
                .frame(width: 340)
            Spacer()
        }
        .onAppear { nameFocused = true }
    }

    private func advance() {
        guard !trimmedName.isEmpty else { return }
        load(onCreate(trimmedName))
        onNameConfirmed(trimmedName)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            stage = .building
        }
    }

    private func load(_ env: SwitchboardCore.Environment) {
        actions = env.actions.map { DraftAction(name: $0.name, prompt: $0.prompt) }
        cleanups = (env.cleanup ?? []).map { DraftAction(name: $0.name, prompt: $0.prompt) }
    }

    // MARK: Stage 2 — action & cleanup lists, chat as a right pane

    private var buildingView: some View {
        HStack(spacing: 0) {
            leftColumn
                .frame(width: 560)

            if chatOpen {
                Divider()
                chatPane
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onAppear {
            // Entering via "edit environment": load its existing actions.
            if stage == .building {
                if actions.isEmpty && cleanups.isEmpty {
                    load(onCreate(trimmedName))
                }
                onNameConfirmed(trimmedName)
            }
        }
        .onChange(of: addActionRequest) { _ in
            guard stage == .building else { return }
            startNewAction(isCleanup: false)
        }
    }

    private var leftColumn: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if actions.isEmpty {
                    Text("No actions yet — add one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                } else {
                    ForEach(actions) { action in
                        row(action, isCleanup: false)
                    }
                }

                HStack {
                    Text("Cleanup — runs on Finish task")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        startNewAction(isCleanup: true)
                    } label: {
                        Label("Add cleanup", systemImage: "plus")
                            .font(.caption)
                    }
                    .disabled(chatOpen)
                }
                .padding(.horizontal, 4)
                .padding(.top, 14)
                .padding(.bottom, 4)

                if cleanups.isEmpty {
                    Text("No cleanup actions — the environment's windows are still closed on Finish.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else {
                    ForEach(cleanups) { action in
                        row(action, isCleanup: true)
                    }
                }
            }
            .padding(10)
        }
    }

    private func row(_ action: DraftAction, isCleanup: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.name).font(.system(size: 13, weight: .medium))
                Text(action.prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            CopyButton(text: action.prompt, help: "Copy action description")
            Button {
                startEditing(action, isCleanup: isCleanup)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Edit this action with Claude")
            ConfirmActionButton(help: "Delete action") {
                withAnimation(.easeInOut(duration: 0.28)) {
                    if isCleanup {
                        cleanups.removeAll { $0.id == action.id }
                    } else {
                        actions.removeAll { $0.id == action.id }
                    }
                }
                onRemoveAction(trimmedName, action.name, isCleanup)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    private var chatPane: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
                Text(chatTitle)
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
                let isCleanup = designingCleanup
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    let draft = DraftAction(name: spec.name, prompt: spec.prompt)
                    if isCleanup {
                        if let replacing, let i = cleanups.firstIndex(where: { $0.name == replacing }) {
                            cleanups[i] = draft
                        } else {
                            cleanups.append(draft)
                        }
                    } else if let replacing, let i = actions.firstIndex(where: { $0.name == replacing }) {
                        actions[i] = draft
                    } else {
                        actions.append(draft)
                    }
                    chatOpen = false
                }
                onSaveAction(trimmedName, spec, proposal.commands, replacing, isCleanup)
                editingActionName = nil
                chat.reset()
            }
        }
    }

    private var chatTitle: String {
        if let editingActionName {
            return "Edit '\(editingActionName)'"
        }
        return designingCleanup ? "Design cleanup with Claude" : "Design action with Claude"
    }

    /// Opens the chat for a brand-new action, discarding any leftover
    /// conversation so contexts never leak between actions.
    private func startNewAction(isCleanup: Bool) {
        if editingActionName != nil || designingCleanup != isCleanup {
            editingActionName = nil
            chat.reset()
        }
        designingCleanup = isCleanup
        if isCleanup {
            chat.prepare(context: """
            The user is designing a CLEANUP action: it tears the environment down when the
            task is finished (stop dev servers or containers, remove worktrees, etc.).
            Closing windows is handled by the app — cleanup commands should stop processes
            and release resources, not close windows.
            """)
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            chatOpen = true
        }
    }

    /// Opens the chat primed with the action's current definition so the
    /// conversation starts from its existing intent and commands.
    private func startEditing(_ action: DraftAction, isCleanup: Bool) {
        editingActionName = action.name
        designingCleanup = isCleanup
        chat.reset()

        let spec = ActionSpec(name: action.name, prompt: action.prompt)
        let cacheEnv = isCleanup ? Opener.cleanupCacheEnv(trimmedName) : trimmedName
        let cached = CommandCache.lookup(env: cacheEnv, action: spec)
        var context = """
        The user is EDITING an existing \(isCleanup ? "CLEANUP " : "")action rather than creating a new one.
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
