import SwiftUI
import SwitchboardCore

/// Root overlay content: environment list, or the new-environment form.
struct OverlayView: View {
    @State private var config: Config
    @State private var creating = false
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
            if creating {
                NewEnvironmentView(
                    onSave: { env in
                        config.environments.append(env)
                        persist()
                        creating = false
                    },
                    onCancel: { creating = false }
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
        .frame(width: 560, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, lineWidth: 1))
    }

    private var listView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "rectangle.3.group")
                Text("Switchboard").font(.headline)
                Spacer()
                Button {
                    creating = true
                } label: {
                    Label("New Environment", systemImage: "plus")
                }
            }
            .padding(14)

            Divider()

            if config.environments.isEmpty {
                Spacer()
                Text("No environments yet — create one.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(config.environments) { env in
                            EnvironmentRow(env: env) {
                                onOpen(env)
                                onDismiss()
                            }
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

struct EnvironmentRow: View {
    let env: SwitchboardCore.Environment
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(env.name).font(.system(size: 14, weight: .medium))
                    Text(env.actions.map(\.name).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(hovering ? .primary : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovering ? Color.accentColor.opacity(0.15) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Form for creating a new environment: name + a list of action name/prompt rows.
struct NewEnvironmentView: View {
    struct DraftAction: Identifiable {
        let id = UUID()
        var name = ""
        var prompt = ""
    }

    @State private var name = ""
    @State private var actions: [DraftAction] = [DraftAction()]

    let onSave: (SwitchboardCore.Environment) -> Void
    let onCancel: () -> Void

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !actions.isEmpty
            && actions.allSatisfy {
                !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                    && !$0.prompt.trimmingCharacters(in: .whitespaces).isEmpty
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Environment").font(.headline)
                Spacer()
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Environment name", text: $name)
                        .textFieldStyle(.roundedBorder)

                    Text("Actions").font(.subheadline.weight(.semibold))

                    ForEach($actions) { $action in
                        VStack(spacing: 6) {
                            HStack {
                                TextField("Action name (e.g. browser)", text: $action.name)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 180)
                                Spacer()
                                if actions.count > 1 {
                                    Button {
                                        actions.removeAll { $0.id == action.id }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            TextField("What should this action do? (plain English)", text: $action.prompt, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...4)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                    }

                    Button {
                        actions.append(DraftAction())
                    } label: {
                        Label("Add action", systemImage: "plus")
                    }
                }
                .padding(14)
            }

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    let env = SwitchboardCore.Environment(
                        name: name.trimmingCharacters(in: .whitespaces),
                        actions: actions.map {
                            ActionSpec(
                                name: $0.name.trimmingCharacters(in: .whitespaces),
                                prompt: $0.prompt.trimmingCharacters(in: .whitespaces)
                            )
                        }
                    )
                    onSave(env)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(14)
        }
    }
}
