import Foundation

/// The storage layout under ~/.config/switchboard/:
///   settings.json         app settings (hotkey, …)
///   templates.json        template records
///   environments.json     active environments incl. window data
///   chats/<uuid>.json     one design conversation per file
///   cache.json            prompt → command cache (see CommandCache)
public enum StoreDir {
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/switchboard")

    static func ensure() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        StoreDir.ensure()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(value).write(to: url)
    }
}

public enum SettingsStore {
    public static let url = StoreDir.url.appendingPathComponent("settings.json")

    public static func load() -> Settings {
        JSONFile.read(Settings.self, at: url) ?? Settings()
    }

    public static func save(_ settings: Settings) {
        JSONFile.write(settings, to: url)
    }
}

public enum TemplateStore {
    public static let url = StoreDir.url.appendingPathComponent("templates.json")

    public static func load() -> [Environment] {
        JSONFile.read([Environment].self, at: url) ?? []
    }

    public static func save(_ templates: [Environment]) {
        JSONFile.write(templates, to: url)
    }
}

public enum EnvironmentStore {
    public static let url = StoreDir.url.appendingPathComponent("environments.json")
    private static let lock = NSLock()

    public static func load() -> [Environment] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    public static func save(_ environments: [Environment]) {
        lock.lock()
        defer { lock.unlock() }
        JSONFile.write(environments, to: url)
    }

    public static func find(_ id: UUID) -> Environment? {
        load().first { $0.id == id }
    }

    /// Atomically mutates one environment record by id (used by the window
    /// tracker from background threads).
    public static func update(_ id: UUID, _ mutate: (inout Environment) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var environments = loadLocked()
        guard let i = environments.firstIndex(where: { $0.id == id }) else { return }
        mutate(&environments[i])
        JSONFile.write(environments, to: url)
    }

    private static func loadLocked() -> [Environment] {
        JSONFile.read([Environment].self, at: url) ?? []
    }
}

public enum ChatStore {
    public static let dir = StoreDir.url.appendingPathComponent("chats")

    public static func url(for id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).json")
    }

    public static func load(_ id: UUID) -> ChatRecord? {
        JSONFile.read(ChatRecord.self, at: url(for: id))
    }

    /// Appends a session's messages to the chat record, creating it if new.
    public static func append(_ id: UUID, messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var record = load(id) ?? ChatRecord(id: id, messages: [], updatedAt: Date())
        record.messages += messages
        record.updatedAt = Date()
        JSONFile.write(record, to: url(for: id))
    }
}

/// One-shot split of the legacy single-file layout (config.json + state.json)
/// into the per-concern files above. Safe to call on every launch.
public enum Migration {
    public static func run() {
        StoreDir.ensure()
        let fm = FileManager.default
        let legacyConfigURL = StoreDir.url.appendingPathComponent("config.json")
        let legacyStateURL = StoreDir.url.appendingPathComponent("state.json")

        guard !fm.fileExists(atPath: EnvironmentStore.url.path) else { return }

        struct Legacy: Decodable {
            var environments: [Environment]
            var templates: [Environment]?
            var hotkey: HotKeyConfig?
        }

        if let data = try? Data(contentsOf: legacyConfigURL),
           let legacy = try? JSONDecoder().decode(Legacy.self, from: data) {
            var environments = legacy.environments

            // Fold the old window-tracking state (keyed by env name) into the records.
            if let stateData = try? Data(contentsOf: legacyStateURL),
               let state = try? JSONDecoder().decode([String: [WindowRef]].self, from: stateData) {
                for (name, windows) in state {
                    if let i = environments.firstIndex(where: { $0.name == name }) {
                        environments[i].windows = windows
                    }
                }
            }

            EnvironmentStore.save(environments)
            TemplateStore.save(legacy.templates ?? [])
            SettingsStore.save(Settings(hotkey: legacy.hotkey))
            try? fm.moveItem(at: legacyConfigURL, to: legacyConfigURL.appendingPathExtension("bak"))
            try? fm.moveItem(at: legacyStateURL, to: legacyStateURL.appendingPathExtension("bak"))
            FileHandle.standardError.write(Data("Migrated config to split stores in \(StoreDir.url.path)\n".utf8))
            return
        }

        // Fresh install: seed a sample environment.
        let sample = Environment(name: "sample", actions: [
            ActionSpec(name: "browser", prompt: "Open a new Google Chrome window showing https://example.com"),
            ActionSpec(name: "editor", prompt: "Open VS Code at ~/switchboard"),
            ActionSpec(name: "terminal", prompt: "Open a new iTerm window, cd to ~/switchboard and print 'Switchboard environment ready'"),
        ])
        EnvironmentStore.save([sample])
        FileHandle.standardError.write(Data("Created sample environment store at \(EnvironmentStore.url.path)\n".utf8))
    }
}
