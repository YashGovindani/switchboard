import SwiftUI
import SwitchboardCore

extension Notification.Name {
    static let switchboardPanelResize = Notification.Name("switchboard.panelResize")
}

/// Root overlay content: environment list, or the environment builder.
struct OverlayView: View {
    @State private var environments: [SwitchboardCore.Environment]
    @State private var templates: [SwitchboardCore.Environment]
    @State private var creating = false
    @State private var editingEnv: UUID?
    @State private var builderName: String?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var addActionRequest = 0
    @State private var chatOpen = false
    @State private var templateSaved = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var searchFocused: Bool

    let onOpen: (SwitchboardCore.Environment) -> Void
    let onFinish: (SwitchboardCore.Environment) -> Void
    let onDismiss: () -> Void

    init(
        environments: [SwitchboardCore.Environment],
        templates: [SwitchboardCore.Environment],
        onOpen: @escaping (SwitchboardCore.Environment) -> Void,
        onFinish: @escaping (SwitchboardCore.Environment) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _environments = State(initialValue: environments)
        _templates = State(initialValue: templates)
        self.onOpen = onOpen
        self.onFinish = onFinish
        self.onDismiss = onDismiss
    }

    private var filtered: [SwitchboardCore.Environment] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return environments }
        return environments.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
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
            initialEnv: environments.first { $0.id == editingEnv },
            addActionRequest: addActionRequest,
            templates: templates,
            onEnvReady: { env in
                withAnimation(.easeInOut(duration: 0.28)) { builderName = env.name }
                editingEnv = env.id
            },
            onCreate: { name, templateID in
                if let existing = environments.first(where: { $0.name == name }) {
                    return existing
                }
                var fresh = SwitchboardCore.Environment(name: name, actions: [])
                if let templateID,
                   let template = templates.first(where: { $0.id == templateID }) {
                    // Copy the template's actions with fresh record ids but
                    // shared chat links, and bring its cached commands along.
                    fresh = SwitchboardCore.Environment(
                        name: name,
                        templateID: template.id,
                        actions: template.actions.map {
                            ActionSpec(name: $0.name, prompt: $0.prompt, chatID: $0.chatID)
                        },
                        cleanup: template.cleanup?.map {
                            ActionSpec(name: $0.name, prompt: $0.prompt, chatID: $0.chatID)
                        }
                    )
                    CommandCache.copyNamespace(from: "template:\(template.name)", to: name)
                }
                environments.append(fresh)
                persistEnvironments()
                return fresh
            },
            onDeleteTemplate: { templateID in
                if let template = templates.first(where: { $0.id == templateID }) {
                    CommandCache.removeAll(env: "template:\(template.name)")
                }
                templates.removeAll { $0.id == templateID }
                TemplateStore.save(templates)
            },
            onSaveAction: { envID, action, commands, replacingID, isCleanup in
                guard let i = environments.firstIndex(where: { $0.id == envID }) else { return }
                if isCleanup {
                    var cleanup = environments[i].cleanup ?? []
                    if let replacingID, let j = cleanup.firstIndex(where: { $0.id == replacingID }) {
                        cleanup[j] = action
                    } else {
                        cleanup.append(action)
                    }
                    environments[i].cleanup = cleanup
                } else if let replacingID,
                          let j = environments[i].actions.firstIndex(where: { $0.id == replacingID }) {
                    environments[i].actions[j] = action
                } else {
                    environments[i].actions.append(action)
                }
                persistEnvironments()
                // The chat already produced the commands — cache them so
                // opening/finishing never needs a re-translation.
                let cacheEnv = isCleanup ? Opener.cleanupCacheEnv(environments[i].name) : environments[i].name
                try? CommandCache.store(env: cacheEnv, action: action, commands: commands)
            },
            onRemoveAction: { envID, actionID, isCleanup in
                guard let i = environments.firstIndex(where: { $0.id == envID }) else { return }
                if isCleanup {
                    environments[i].cleanup?.removeAll { $0.id == actionID }
                } else {
                    environments[i].actions.removeAll { $0.id == actionID }
                }
                persistEnvironments()
            }
        )
        .id("\(editingEnv?.uuidString ?? "new")-\(builderName ?? "")")
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
                        editingEnv = nil
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
                        saveTemplate()
                    } label: {
                        Image(systemName: templateSaved ? "checkmark.circle.fill" : "square.on.square")
                            .foregroundStyle(templateSaved ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .help("Save this environment's actions as a template")
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

    /// Snapshots the current environment's actions + cleanup as a template
    /// (named after the environment; saving again overwrites), including its
    /// cached commands so instantiations never re-translate.
    private func saveTemplate() {
        guard let envID = editingEnv,
              let env = environments.first(where: { $0.id == envID })
        else { return }
        if let i = templates.firstIndex(where: { $0.name == env.name }) {
            templates[i].actions = env.actions
            templates[i].cleanup = env.cleanup
        } else {
            templates.append(SwitchboardCore.Environment(name: env.name, actions: env.actions, cleanup: env.cleanup))
        }
        TemplateStore.save(templates)
        CommandCache.removeAll(env: "template:\(env.name)")
        CommandCache.copyNamespace(from: env.name, to: "template:\(env.name)")

        withAnimation { templateSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { templateSaved = false }
        }
    }

    private func commitRename() {
        let new = renameText.trimmingCharacters(in: .whitespaces)
        guard let envID = editingEnv,
              let i = environments.firstIndex(where: { $0.id == envID }),
              !new.isEmpty
        else {
            renaming = false
            return
        }
        let old = environments[i].name
        guard new != old else {
            renaming = false
            return
        }
        guard !environments.contains(where: { $0.name == new }) else {
            errorMessage = "An environment named '\(new)' already exists."
            return
        }
        environments[i].name = new
        persistEnvironments()
        CommandCache.renameEnv(old, to: new)
        builderName = new
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
                Text(environments.isEmpty ? "No environments yet — create one." : "No match.")
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
                                        editingEnv = env.id
                                        builderName = env.name
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            creating = true
                                        }
                                    },
                                    onDelete: {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                            environments.removeAll { $0.id == env.id }
                                        }
                                        persistEnvironments()
                                        CommandCache.removeAll(env: env.name)
                                    }
                                )
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: selected) { index in
                        guard filtered.indices.contains(index) else { return }
                        withAnimation { proxy.scrollTo(filtered[index].id) }
                    }
                    .onChange(of: filtered.count) { count in
                        selected = min(selected, max(count - 1, 0))
                    }
                }
            }
        }
    }

    /// Saves the UI's view of the environments, preserving the window data
    /// the tracker maintains on disk from background threads.
    private func persistEnvironments() {
        let onDisk = EnvironmentStore.load()
        var toSave = environments
        for i in toSave.indices {
            if let disk = onDisk.first(where: { $0.id == toSave[i].id }) {
                toSave[i].windows = disk.windows
            }
        }
        EnvironmentStore.save(toSave)
        errorMessage = nil
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
/// 1. A single centered name field (optionally selecting a template).
/// 2. Action and cleanup lists, with the chat as a full-height right pane
///    while designing an action.
struct NewEnvironmentView: View {
    private enum Stage {
        case askName, building
    }

    @State private var stage: Stage
    @State private var name: String
    @State private var envID: UUID?
    @State private var actions: [ActionSpec]
    @State private var cleanups: [ActionSpec]
    @State private var editingAction: ActionSpec?
    @State private var designingCleanup = false
    @State private var selectedTemplate: UUID?
    @Binding var chatOpen: Bool
    @StateObject private var chat = ActionChatModel()
    @FocusState private var nameFocused: Bool

    /// Incremented by the header's Add action button; observed to open the chat.
    let addActionRequest: Int
    /// Saved templates offered on the name screen.
    let templates: [SwitchboardCore.Environment]
    /// Reports the created/loaded environment record so the header can show it.
    let onEnvReady: (SwitchboardCore.Environment) -> Void
    /// Creates/persists the environment (from the template id, when given)
    /// and returns its record.
    let onCreate: (String, UUID?) -> SwitchboardCore.Environment
    let onDeleteTemplate: (UUID) -> Void
    /// Persists an agreed action and its ready-made commands immediately.
    /// `replacing` is the id of the action being replaced on edit.
    let onSaveAction: (UUID, ActionSpec, [String], UUID?, Bool) -> Void
    let onRemoveAction: (UUID, UUID, Bool) -> Void

    init(
        chatOpen: Binding<Bool>,
        initialEnv: SwitchboardCore.Environment? = nil,
        addActionRequest: Int = 0,
        templates: [SwitchboardCore.Environment] = [],
        onEnvReady: @escaping (SwitchboardCore.Environment) -> Void,
        onCreate: @escaping (String, UUID?) -> SwitchboardCore.Environment,
        onDeleteTemplate: @escaping (UUID) -> Void = { _ in },
        onSaveAction: @escaping (UUID, ActionSpec, [String], UUID?, Bool) -> Void,
        onRemoveAction: @escaping (UUID, UUID, Bool) -> Void
    ) {
        _chatOpen = chatOpen
        _stage = State(initialValue: initialEnv == nil ? .askName : .building)
        _name = State(initialValue: initialEnv?.name ?? "")
        _envID = State(initialValue: initialEnv?.id)
        _actions = State(initialValue: initialEnv?.actions ?? [])
        _cleanups = State(initialValue: initialEnv?.cleanup ?? [])
        self.addActionRequest = addActionRequest
        self.templates = templates
        self.onEnvReady = onEnvReady
        self.onCreate = onCreate
        self.onDeleteTemplate = onDeleteTemplate
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

    // MARK: Stage 1 — name (+ optional template)

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

            if !templates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedTemplateName == nil
                        ? "Optionally start from a template"
                        : "Starting from '\(selectedTemplateName!)' — name it and press Enter")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(templates) { template in
                        let isSelected = selectedTemplate == template.id
                        HStack(spacing: 8) {
                            Button {
                                selectedTemplate = isSelected ? nil : template.id
                                nameFocused = true
                            } label: {
                                HStack {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "square.on.square")
                                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(template.name).font(.system(size: 13, weight: .medium))
                                        Text(template.actions.map(\.name).joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            ConfirmActionButton(help: "Delete template") {
                                if selectedTemplate == template.id { selectedTemplate = nil }
                                onDeleteTemplate(template.id)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected
                                    ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                                    : AnyShapeStyle(.quaternary.opacity(0.4)))
                        )
                    }
                }
                .frame(width: 340)
                .padding(.top, 18)
            }
            Spacer()
        }
        .onAppear { nameFocused = true }
    }

    private var selectedTemplateName: String? {
        selectedTemplate.flatMap { id in templates.first { $0.id == id }?.name }
    }

    private func advance() {
        guard !trimmedName.isEmpty else { return }
        let env = onCreate(trimmedName, selectedTemplate)
        envID = env.id
        actions = env.actions
        cleanups = env.cleanup ?? []
        onEnvReady(env)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            stage = .building
        }
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

    private func row(_ action: ActionSpec, isCleanup: Bool) -> some View {
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
                guard let envID else { return }
                withAnimation(.easeInOut(duration: 0.28)) {
                    if isCleanup {
                        cleanups.removeAll { $0.id == action.id }
                    } else {
                        actions.removeAll { $0.id == action.id }
                    }
                }
                onRemoveAction(envID, action.id, isCleanup)
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
                guard let envID else { return }
                let replacing = editingAction
                let isCleanup = designingCleanup

                // Persist this session's conversation, linked from the action.
                let chatID = replacing?.chatID ?? UUID()
                ChatStore.append(chatID, messages: chat.newTranscript())

                let spec = ActionSpec(name: proposal.name, prompt: proposal.intent, chatID: chatID)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if isCleanup {
                        if let replacing, let i = cleanups.firstIndex(where: { $0.id == replacing.id }) {
                            cleanups[i] = spec
                        } else {
                            cleanups.append(spec)
                        }
                    } else if let replacing, let i = actions.firstIndex(where: { $0.id == replacing.id }) {
                        actions[i] = spec
                    } else {
                        actions.append(spec)
                    }
                    chatOpen = false
                }
                onSaveAction(envID, spec, proposal.commands, replacing?.id, isCleanup)
                editingAction = nil
                chat.reset()
            }
        }
    }

    private var chatTitle: String {
        if let editingAction {
            return "Edit '\(editingAction.name)'"
        }
        return designingCleanup ? "Design cleanup with Claude" : "Design action with Claude"
    }

    /// Opens the chat for a brand-new action, discarding any leftover
    /// conversation so contexts never leak between actions.
    private func startNewAction(isCleanup: Bool) {
        if editingAction != nil || designingCleanup != isCleanup {
            editingAction = nil
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

    /// Opens the chat primed with the action's current definition — and its
    /// stored conversation history, when it has one.
    private func startEditing(_ action: ActionSpec, isCleanup: Bool) {
        editingAction = action
        designingCleanup = isCleanup
        chat.reset()

        if let chatID = action.chatID, let record = ChatStore.load(chatID) {
            chat.preload(record.messages)
        }

        let cacheEnv = isCleanup ? Opener.cleanupCacheEnv(trimmedName) : trimmedName
        let cached = CommandCache.lookup(env: cacheEnv, action: action)
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
