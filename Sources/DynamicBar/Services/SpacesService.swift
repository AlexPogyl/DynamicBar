import AppKit
import CoreGraphics

/// Рабочие столы (Spaces) через приватные API SkyLight.
///
/// Публичного способа узнать, на каком рабочем столе живёт окно, в macOS нет.
/// SkyLight даёт всё нужное:
///   * `CGSCopyManagedDisplaySpaces` — список столов и активный из них,
///   * `CGSCopyWindowsWithOptionsAndTags` — окна конкретного стола,
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
    private typealias CopyWindowsFn = @convention(c) (UInt32, UInt32, CFArray?, UInt32,
                                                      UnsafeMutablePointer<UInt64>?,
                                                      UnsafeMutablePointer<UInt64>?) -> CFArray?
    private typealias GetActiveSpaceFn = @convention(c) (UInt32) -> UInt64
    private typealias SetCurrentSpaceFn = @convention(c) (UInt32, CFString?, UInt64) -> Int32

    private var mainConnection: MainConnectionFn?
    private var copyManagedDisplays: CopyManagedDisplaysFn?
    private var copyWindows: CopyWindowsFn?
    private var getActiveSpace: GetActiveSpaceFn?
    private var setCurrentSpace: SetCurrentSpaceFn?

    private var connection: UInt32 = 0
    private(set) var isAvailable = false

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
        copyWindows = symbol("CGSCopyWindowsWithOptionsAndTags")
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
        isAvailable = connection != 0 && copyWindows != nil && setCurrentSpace != nil
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
        let active = activeSpaceID()
        let raw = displayDictionaries().first?["Spaces"] as? [[String: Any]] ?? []
        return raw.enumerated().compactMap { offset, dict in
            guard let id = dict["id64"] as? Int else { return nil }
            return Space(id: id, index: offset + 1, isActive: id == active)
        }
    }

    func activeSpaceID() -> Int? {
        guard let getActiveSpace, connection != 0 else { return nil }
        let value = getActiveSpace(connection)
        return value == 0 ? nil : Int(value)
    }

    // MARK: - Окна по столам

    /// Номера обычных окон (слой 0) на указанном столе.
    private func windowNumbers(onSpace id: Int) -> [Int] {
        guard let copyWindows, connection != 0 else { return [] }
        let spaceArray = [NSNumber(value: id)] as CFArray
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let windows = copyWindows(connection, 0, spaceArray, 0, &setTags, &clearTags) else { return [] }
        var numbers: [Int] = []
        for index in 0..<CFArrayGetCount(windows) {
            guard let raw = CFArrayGetValueAtIndex(windows, index),
                  let number = (Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? NSNumber)?.intValue else { continue }
            numbers.append(number)
        }
        return numbers
    }

    /// Полный снимок: столы, активный стол и какие процессы на каких столах.
    ///
    /// `CGSCopyWindowsWithOptionsAndTags` возвращает окна всех слоёв, поэтому
    /// результат пересекается со списком окон: нужны только обычные окна, иначе
    /// в столы попадут панели, обои и служебные окна.
    func snapshot() -> Snapshot {
        var result = Snapshot()
        guard isAvailable else { return result }

        result.spaces = spaces()
        result.activeSpaceID = activeSpaceID()

        var layerByNumber: [Int: Int] = [:]
        var pidByNumber: [Int: pid_t] = [:]
        if let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for entry in list {
                guard let number = entry[kCGWindowNumber as String] as? Int else { continue }
                layerByNumber[number] = entry[kCGWindowLayer as String] as? Int ?? -1
                if let pid = entry[kCGWindowOwnerPID as String] as? Int { pidByNumber[number] = pid_t(pid) }
            }
        }

        for space in result.spaces {
            for number in windowNumbers(onSpace: space.id) {
                guard layerByNumber[number] == 0, let pid = pidByNumber[number] else { continue }
                var list = result.spacesByPID[pid] ?? []
                if !list.contains(space.id) { list.append(space.id) }
                result.spacesByPID[pid] = list.sorted()
            }
        }
        return result
    }

    // MARK: - Переключение

    /// Перейти на указанный стол. Возвращает true, если система подтвердила переход.
    @discardableResult
    func switchTo(spaceID: Int) -> Bool {
        guard let setCurrentSpace, connection != 0 else { return false }
        if activeSpaceID() == spaceID { return true }
        _ = setCurrentSpace(connection, displayIdentifier() as CFString, UInt64(spaceID))
        // Даём оконному серверу доехать: чтение сразу после вызова вернуло бы
        // прежний стол и проверка была бы ложной.
        for _ in 0..<12 {
            usleep(60_000)
            if activeSpaceID() == spaceID { return true }
        }
        Log.error("spaces: не удалось перейти на стол \(spaceID)")
        return false
    }
}
