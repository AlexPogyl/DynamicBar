import AppKit

/// Как вкладка «Приложения» показывает запущенные приложения.
enum AppsDisplayMode: String, CaseIterable, Identifiable {
    /// Все запущенные приложения и закладки.
    case all
    /// Закладки плюс приложения, у которых есть окно на активном рабочем столе.
    case activeSpace
    /// Закладки плюс приложения, разложенные по рабочим столам.
    case bySpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Все запущенные приложения и закладки"
        case .activeSpace: return "Только приложения активного рабочего стола"
        case .bySpace: return "Приложения по рабочим столам"
        }
    }

    var shortTitle: String {
        switch self {
        case .all: return "Все"
        case .activeSpace: return "Активный стол"
        case .bySpace: return "По столам"
        }
    }

    var explanation: String {
        switch self {
        case .all:
            return "Показываются все запущенные приложения и все закладки."
        case .activeSpace:
            return "Закладки и только те приложения, у которых есть окно на текущем рабочем столе."
        case .bySpace:
            return "Закладки, а дальше приложения разложены по рабочим столам. Клик по приложению с другого стола переносит на этот стол."
        }
    }
}

/// Группа иконок на вкладке.
struct AppsGroup: Identifiable, Equatable {
    let id: String
    /// nil — группа без заголовка (режим «все» рисуется как сплошная сетка).
    let title: String?
    let isActiveSpace: Bool
    var pinned: [PinnedItem] = []
    var running: [AppEntry] = []

    var isEmpty: Bool { pinned.isEmpty && running.isEmpty }
}

/// Раскладка вкладки «Приложения». Чистая функция: ни окон, ни системы —
/// поэтому её можно проверять тестами без реальных рабочих столов.
enum AppsGrouping {
    static let pinnedGroupID = "pinned"
    static let allGroupID = "all"
    static let activeGroupID = "space-active"
    static let orphanGroupID = "space-none"

    static func groups(mode: AppsDisplayMode,
                       pinned: [PinnedItem],
                       running: [AppEntry],
                       spacesByBundle: [String: [Int]],
                       spaces: [SpacesService.Space],
                       activeSpaceID: Int?) -> [AppsGroup] {
        switch mode {
        case .all:
            return [AppsGroup(id: allGroupID, title: nil, isActiveSpace: false, pinned: pinned, running: running)]

        case .activeSpace:
            var result: [AppsGroup] = [
                AppsGroup(id: pinnedGroupID, title: "Закладки", isActiveSpace: false, pinned: pinned),
            ]
            let active = activeSpaceID
            let onActive = running.filter { entry in
                guard let active else { return true }
                return (spacesByBundle[entry.bundleID] ?? []).contains(active)
            }
            result.append(AppsGroup(
                id: activeGroupID,
                title: activeSpaceID == nil ? "Рабочие столы недоступны" : "Активный стол",
                isActiveSpace: true,
                running: onActive
            ))
            return result.filter { !$0.isEmpty || $0.id == pinnedGroupID }

        case .bySpace:
            var result: [AppsGroup] = [
                AppsGroup(id: pinnedGroupID, title: "Закладки", isActiveSpace: false, pinned: pinned),
            ]

            // Активный стол первым, дальше по порядку; пустые не показываем.
            // Активность берём из activeSpaceID, а не из поля снимка: иначе
            // получалось бы два источника правды, и они могли разойтись.
            func isActive(_ space: SpacesService.Space) -> Bool {
                guard let activeSpaceID else { return false }
                return space.id == activeSpaceID
            }
            let ordered = spaces.sorted { lhs, rhs in
                if isActive(lhs) != isActive(rhs) { return isActive(lhs) }
                return lhs.index < rhs.index
            }
            var used = Set<String>()
            for space in ordered {
                let entries = running.filter { (spacesByBundle[$0.bundleID] ?? []).contains(space.id) }
                guard !entries.isEmpty else { continue }
                entries.forEach { used.insert($0.bundleID) }
                result.append(AppsGroup(
                    id: "space-\(space.id)",
                    title: isActive(space) ? "\(space.title) — активный" : space.title,
                    isActiveSpace: isActive(space),
                    running: entries
                ))
            }

            // Приложения без окон вообще не попадают ни на один стол. Прятать их
            // совсем нельзя: приложение запущено, и до него надо как-то добраться.
            let orphans = running.filter { !used.contains($0.bundleID) }
            if !orphans.isEmpty {
                result.append(AppsGroup(id: orphanGroupID, title: "Без окон", isActiveSpace: false, running: orphans))
            }
            return result.filter { !$0.isEmpty || $0.id == pinnedGroupID }
        }
    }
}
