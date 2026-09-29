import AppKit
import CoreGraphics

/// Рабочие столы (Spaces) через приватные API SkyLight.
///
/// Публичного способа узнать, на каком рабочем столе живёт окно, в macOS нет.
/// SkyLight даёт всё нужное:
///   * `CGSCopyManagedDisplaySpaces` — список столов и активный из них,
///   * `CGSCopySpacesForWindows` — столы конкретного окна (строго по одному),
///   * `CGSManagedDisplaySetCurrentSpace` — переключение на стол.
///
/// Разрешений это не требует. Если Apple уберёт символы, сервис просто
/// сообщит `isAvailable == false`, и вкладка «Приложения» вернётся к показу
/// всех запущенных приложений.
final class SpacesService {
    struct Space: Identifiable, Equatable {
        /// Идентификатор стола (`id64`) — он же используется для переключения.
        let id: Int
        /// Номер по порядку, с единицы: macOS имён столам не хранит.
        let index: Int
        let isActive: Bool

        var title: String { "Стол \(index)" }
    }

    struct Snapshot {
        var spaces: [Space] = []
        var activeSpaceID: Int?
        /// Для каждого процесса — столы, на которых у него есть обычные окна.
        var spacesByPID: [pid_t: [Int]] = [:]

        func spaces(of pid: pid_t) -> [Int] { spacesByPID[pid] ?? [] }
    }

    private typealias MainConnectionFn = @convention(c) () -> UInt32
    private typealias CopyManagedDisplaysFn = @convention(c) (UInt32) -> CFArray?
    private typealias CopySpacesForWindowsFn = @convention(c) (UInt32, Int32, CFArray?) -> CFArray?
    private typealias GetActiveSpaceFn = @convention(c) (UInt32) -> UInt64
    private typealias SetCurrentSpaceFn = @convention(c) (UInt32, CFString?, UInt64) -> Int32

    private var mainConnection: MainConnectionFn?
    private var copyManagedDisplays: CopyManagedDisplaysFn?
    private var copySpacesForWindows: CopySpacesForWindowsFn?
    private var getActiveSpace: GetActiveSpaceFn?
    private var setCurrentSpace: SetCurrentSpaceFn?

    private var connection: UInt32 = 0
    private(set) var isAvailable = false

    /// Приватные вызовы трогают состояние соединения с оконным сервером,
    /// поэтому все обращения к ним идут через одну очередь.
    private let queue = DispatchQueue(label: "com.dynamicbar.spaces")

    init() {
        load()
    }

    private func load() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_NOW) else {
            Log.error("spaces: SkyLight не загрузился — \(String(cString: dlerror()))")
            return
        }
        func symbol<T>(_ name: String) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        mainConnection = symbol("CGSMainConnectionID")
        copyManagedDisplays = symbol("CGSCopyManagedDisplaySpaces")
        copySpacesForWindows = symbol("CGSCopySpacesForWindows")
        getActiveSpace = symbol("CGSGetActiveSpace")
        setCurrentSpace = symbol("CGSManagedDisplaySetCurrentSpace")

        guard let mainConnection,
              let copyManagedDisplays,
              let getActiveSpace else {
            Log.error("spaces: нужные символы SkyLight недоступны")
            return
        }
        _ = copyManagedDisplays
        _ = getActiveSpace
        connection = mainConnection()
        isAvailable = connection != 0 && copySpacesForWindows != nil && setCurrentSpace != nil
        Log.info("spaces: доступны=\(isAvailable), соединение=\(connection)")
    }

    // MARK: - Список столов

    private func displayDictionaries() -> [[String: Any]] {
        guard let copyManagedDisplays, connection != 0 else { return [] }
        return copyManagedDisplays(connection) as? [[String: Any]] ?? []
    }

    private func displayIdentifier() -> String {
        displayDictionaries().first?["Display Identifier"] as? String ?? "Main"
    }

    /// Столы основного дисплея в том порядке, в каком их показывает Mission Control.
    func spaces() -> [Space] {
        queue.sync { spacesLocked() }
    }

    private func spacesLocked() -> [Space] {
        let active = activeSpaceIDLocked()
        let raw = displayDictionaries().first?["Spaces"] as? [[String: Any]] ?? []
        return raw.enumerated().compactMap { offset, dict in
            guard let id = dict["id64"] as? Int else { return nil }
            return Space(id: id, index: offset + 1, isActive: id == active)
        }
    }

    func activeSpaceID() -> Int? {
        queue.sync { activeSpaceIDLocked() }
    }

    private func activeSpaceIDLocked() -> Int? {
        guard let getActiveSpace, connection != 0 else { return nil }
        let value = getActiveSpace(connection)
        return value == 0 ? nil : Int(value)
    }

    // MARK: - Окна по столам

    /// Столы, на которых живёт конкретное окно.
    ///
    /// Спрашивать надо строго по одному окну. Если передать массив из сотни
    /// окон, `CGSCopySpacesForWindows` молча возвращает почти пустой результат —
    /// на этом я и потерял все свёрнутые окна: приложение, чьи окна свёрнуты,
    /// не попадало ни в один стол и пропадало из вкладки.
    private func spacesForWindow(_ number: Int) -> [Int] {
        guard let copySpacesForWindows, connection != 0 else { return [] }
        let windowArray = [NSNumber(value: number)] as CFArray
        guard let result = copySpacesForWindows(connection, 7, windowArray) else { return [] }
        var spaces: [Int] = []
        for index in 0..<CFArrayGetCount(result) {
            guard let raw = CFArrayGetValueAtIndex(result, index),
                  let value = (Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? NSNumber)?.intValue else { continue }
            spaces.append(value)
        }
        return spaces
    }

    /// Полный снимок: столы, активный стол и какие процессы на каких столах.
    ///
    /// `CGSCopyWindowsWithOptionsAndTags` возвращает окна всех слоёв, поэтому
    /// результат пересекается со списком окон: нужны только обычные окна, иначе
    /// в столы попадут панели, обои и служебные окна.
    func snapshot() -> Snapshot {
        queue.sync { snapshotLocked() }
    }

    private func snapshotLocked() -> Snapshot {
        var result = Snapshot()
        guard isAvailable else { return result }

        result.spaces = spacesLocked()
        result.activeSpaceID = activeSpaceIDLocked()

        // Идём от окон к столам, а не наоборот: так в раскладку попадают и
        // свёрнутые окна, которые в списке окон стола не появляются вовсе.
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return result
        }
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int else { continue }
            let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            guard (bounds["Width"] ?? 0) > 0, (bounds["Height"] ?? 0) > 0 else { continue }

            var spaces = result.spacesByPID[pid_t(pid)] ?? []
            for space in spacesForWindow(number) where !spaces.contains(space) {
                spaces.append(space)
            }
            if spaces != result.spacesByPID[pid_t(pid)] {
                result.spacesByPID[pid_t(pid)] = spaces.sorted()
            }
        }
        return result
    }

    // MARK: - Переключение

    /// Перейти на указанный стол. Возвращает true, если система подтвердила переход.
    @discardableResult
    func switchTo(spaceID: Int) -> Bool {
        queue.sync { switchToLocked(spaceID: spaceID) }
    }

    private func switchToLocked(spaceID: Int) -> Bool {
        guard let setCurrentSpace, connection != 0 else { return false }
        if activeSpaceIDLocked() == spaceID { return true }
        _ = setCurrentSpace(connection, displayIdentifier() as CFString, UInt64(spaceID))
        // Даём оконному серверу доехать: чтение сразу после вызова вернуло бы
        // прежний стол и проверка была бы ложной.
        for _ in 0..<12 {
            usleep(60_000)
            if activeSpaceIDLocked() == spaceID { return true }
        }
        Log.error("spaces: не удалось перейти на стол \(spaceID)")
        return false
    }
}
