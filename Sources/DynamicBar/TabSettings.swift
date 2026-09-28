import AppKit
import Combine

/// Порядок и видимость вкладок панели.
///
/// Настройка живёт в `UserDefaults`, поэтому переживает перезапуск. Вкладка,
/// добавленная в новой версии, дописывается в конец видимой — обновление не
/// должно прятать новые возможности от пользователя.
final class TabSettings: ObservableObject {
    struct Entry: Codable, Equatable, Identifiable {
        var id: String
        var visible: Bool
    }

    static let storageKey = "tabConfiguration"

    @Published private(set) var entries: [Entry] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Производные

    /// Вкладки в настроенном порядке, только видимые.
    var orderedVisibleTabs: [PanelTab] {
        entries.compactMap { entry in
            guard entry.visible, let tab = PanelTab(rawValue: entry.id) else { return nil }
            return tab
        }
    }

    var visibleCount: Int { orderedVisibleTabs.count }

    func isVisible(_ tab: PanelTab) -> Bool {
        entries.first { $0.id == tab.rawValue }?.visible ?? true
    }

    func index(of tab: PanelTab) -> Int? {
        entries.firstIndex { $0.id == tab.rawValue }
    }

    /// Первая видимая вкладка — куда переключиться, если текущую скрыли.
    var firstVisibleTab: PanelTab? { orderedVisibleTabs.first }

    // MARK: - Изменения

    func setVisible(_ visible: Bool, for tab: PanelTab) {
        guard let index = index(of: tab) else { return }
        // Последнюю видимую вкладку скрыть нельзя: панель без вкладок
        // выглядела бы сломанной, а не пустой.
        if !visible, visibleCount <= 1, entries[index].visible { return }
        entries[index].visible = visible
        persist()
    }

    func toggleVisibility(_ tab: PanelTab) {
        setVisible(!isVisible(tab), for: tab)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var copy = entries
        copy.move(fromOffsets: source, toOffset: destination)
        entries = copy
        persist()
    }

    func move(_ tab: PanelTab, by offset: Int) {
        guard let index = index(of: tab) else { return }
        let target = index + offset
        guard target >= 0, target < entries.count else { return }
        var copy = entries
        let item = copy.remove(at: index)
        copy.insert(item, at: target)
        entries = copy
        persist()
    }

    /// Переезд на конкретную позицию — используется перетаскиванием.
    func move(_ tab: PanelTab, to position: Int) {
        guard let from = index(of: tab) else { return }
        let target = max(0, min(entries.count - 1, position))
        guard target != from else { return }
        var copy = entries
        let item = copy.remove(at: from)
        copy.insert(item, at: target)
        entries = copy
        persist()
    }

    func canMove(_ tab: PanelTab, by offset: Int) -> Bool {
        guard let index = index(of: tab) else { return false }
        let target = index + offset
        return target >= 0 && target < entries.count
    }

    func reset() {
        entries = PanelTab.allCases.map { Entry(id: $0.rawValue, visible: true) }
        persist()
    }

    // MARK: - Хранение

    private func load() {
        var stored: [Entry] = []
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            stored = decoded
        }

        // Сохраняем пользовательский порядок, дописывая недостающие вкладки
        // (новая версия приложения) и выбрасывая неизвестные идентификаторы.
        var result: [Entry] = []
        for entry in stored {
            guard let tab = PanelTab(rawValue: entry.id) else { continue }
            guard !result.contains(where: { $0.id == tab.rawValue }) else { continue }
            result.append(Entry(id: tab.rawValue, visible: entry.visible))
        }
        for tab in PanelTab.allCases where !result.contains(where: { $0.id == tab.rawValue }) {
            result.append(Entry(id: tab.rawValue, visible: true))
        }
        if result.allSatisfy({ !$0.visible }), !result.isEmpty {
            // Испорченное хранилище: хотя бы одна вкладка должна быть видна.
            result[0].visible = true
        }
        entries = result
        if stored != result { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
        Log.debug("tab configuration saved: \(entries.map { "\($0.id)\($0.visible ? "+" : "-")" }.joined(separator: " "))")
    }
}
