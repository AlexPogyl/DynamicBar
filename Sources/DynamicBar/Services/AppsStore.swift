import AppKit
import Combine

/// Закреплённый элемент вкладки «Приложения»: приложение, файл или ссылка.
struct PinnedItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case application
        case file
        case link
    }

    var id: UUID
    var kind: Kind
    var title: String
    var bundleID: String?
    var path: String?
    var url: String?

    init(id: UUID = UUID(), kind: Kind, title: String, bundleID: String? = nil, path: String? = nil, url: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.bundleID = bundleID
        self.path = path
        self.url = url
    }
}

/// Закреплённые приложения, файлы и ссылки.
///
/// Закрепление хранится по идентификатору пакета и пути, а не по объекту
/// `NSRunningApplication`: приложение можно закрыть, а иконка должна остаться
/// и запускать его по клику.
final class AppsStore: ObservableObject {
    @Published private(set) var pinned: [PinnedItem] = []

    private let storeURL = AppPaths.file("apps.json")
    private let saveQueue = DispatchQueue(label: "com.dynamicbar.apps.save")
    private var iconCache: [String: NSImage] = [:]

    init() {
        load()
    }

    // MARK: - Изменения

    func pin(_ application: NSRunningApplication) {
        guard let bundleID = application.bundleIdentifier else { return }
        guard !isPinned(bundleID: bundleID) else { return }
        let item = PinnedItem(
            kind: .application,
            title: application.localizedName ?? bundleID,
            bundleID: bundleID,
            path: application.bundleURL?.path
        )
        pinned.append(item)
        persist()
        Log.info("apps: pinned \(item.title)")
    }

    @discardableResult
    func addLink(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized), url.host != nil else { return false }
        pinned.append(PinnedItem(kind: .link, title: url.host ?? normalized, url: normalized))
        persist()
        Log.info("apps: added link \(url.host ?? normalized)")
        return true
    }

    @discardableResult
    func addFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        pinned.append(PinnedItem(kind: .file, title: url.lastPathComponent, path: url.path))
        persist()
        Log.info("apps: added file \(url.lastPathComponent)")
        return true
    }

    func remove(_ item: PinnedItem) {
        pinned.removeAll { $0.id == item.id }
        persist()
    }

    func unpin(bundleID: String) {
        pinned.removeAll { $0.bundleID == bundleID }
        persist()
    }

    func isPinned(bundleID: String) -> Bool {
        pinned.contains { $0.bundleID == bundleID }
    }

    func move(_ item: PinnedItem, by offset: Int) {
        guard let index = pinned.firstIndex(where: { $0.id == item.id }) else { return }
        let target = index + offset
        guard target >= 0, target < pinned.count else { return }
        var copy = pinned
        let moved = copy.remove(at: index)
        copy.insert(moved, at: target)
        pinned = copy
        persist()
    }

    // MARK: - Иконки

    /// Иконка элемента. Для приложения берётся из его пакета, поэтому
    /// закреплённое, но закрытое приложение всё равно выглядит правильно.
    func icon(for item: PinnedItem) -> NSImage? {
        switch item.kind {
        case .application:
            if let bundleID = item.bundleID,
               let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let icon = running.icon {
                return icon
            }
            if let path = item.path {
                return cachedIcon(key: path) { NSWorkspace.shared.icon(forFile: path) }
            }
            return nil
        case .file:
            guard let path = item.path else { return nil }
            return cachedIcon(key: path) { NSWorkspace.shared.icon(forFile: path) }
        case .link:
            return nil
        }
    }

    private func cachedIcon(key: String, make: () -> NSImage) -> NSImage {
        if let cached = iconCache[key] { return cached }
        let image = make()
        iconCache[key] = image
        return image
    }

    /// Приложение по элементу: запущенное или найденное по пути.
    func runningApplication(for item: PinnedItem) -> NSRunningApplication? {
        guard item.kind == .application, let bundleID = item.bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    // MARK: - Хранение

    private func persist() {
        let snapshot = pinned
        let url = storeURL
        saveQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                Log.error("apps persist failed: \(error)")
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            pinned = try JSONDecoder().decode([PinnedItem].self, from: data)
            Log.info("apps: loaded \(pinned.count) pinned item(s)")
        } catch {
            Log.error("apps decode failed: \(error)")
        }
    }
}

/// Приложение в сетке вкладки. Отдельная модель нужна, чтобы список можно было
/// наполнить демонстрационными данными для скриншотов: у незапущенного
/// приложения объекта `NSRunningApplication` не существует.
struct AppEntry: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    /// nil — приложение показано только для демонстрации.
    let application: NSRunningApplication?

    var id: String { bundleID }

    static func == (lhs: AppEntry, rhs: AppEntry) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.name == rhs.name
    }
}

/// Список запущенных приложений с обновлением по уведомлениям рабочего стола.
final class RunningAppsMonitor: ObservableObject {
    @Published private(set) var entries: [AppEntry] = []

    var applications: [NSRunningApplication] { entries.compactMap(\.application) }

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
            observers.append(observer)
        }
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// Только обычные приложения: у агентов и фоновых служб нет ни иконки в
    /// Dock, ни смысла в этой панели. Себя тоже не показываем.
    func refresh() {
        guard !isPreview else { return }
        let ownBundle = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var result: [AppEntry] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            guard let bundleID = app.bundleIdentifier, bundleID != ownBundle else { continue }
            guard app.bundleURL != nil else { continue }
            guard seen.insert(bundleID).inserted else { continue }
            result.append(AppEntry(bundleID: bundleID,
                                   name: app.localizedName ?? bundleID,
                                   icon: app.icon,
                                   application: app))
        }

        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if result.map(\.bundleID) != entries.map(\.bundleID) {
            entries = result
        }
    }

    private var isPreview = false

    /// Демонстрационный набор для скриншотов: иконки берутся у системных
    /// приложений, поэтому в кадр не попадает ничего личного.
    func loadPreviewApplications() {
        isPreview = true
        let names = ["Safari", "Mail", "Messages", "Calendar", "Notes", "Music", "Photos", "Terminal"]
        entries = names.compactMap { name in
            let path = "/System/Applications/\(name).app"
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return AppEntry(bundleID: "demo.\(name)",
                            name: name,
                            icon: NSWorkspace.shared.icon(forFile: path),
                            application: nil)
        }
        Log.debug("apps: загружен демонстрационный список из \(entries.count) приложений")
    }
}
