import AppKit
import Combine

enum PanelTab: String, CaseIterable, Identifiable {
    case clipboard
    case snippets
    case notes
    case apps
    case translator
    case music

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: return "Буфер"
        case .snippets: return "Сниппеты"
        case .notes: return "Заметки"
        case .apps: return "Приложения"
        case .translator: return "Переводчик"
        case .music: return "Музыка"
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        case .snippets: return "text.badge.plus"
        case .notes: return "note.text"
        case .apps: return "square.grid.2x2"
        case .translator: return "character.book.closed"
        case .music: return "music.note"
        }
    }

    var subtitle: String {
        switch self {
        case .clipboard: return "История скопированного текста"
        case .snippets: return "Заготовки, которые копируются в один клик"
        case .notes: return "Свободные записи с автосохранением"
        case .apps: return "Запущенные приложения, файлы и ссылки"
        case .translator: return "Английский ↔ русский"
        case .music: return "Управление системным воспроизведением"
        }
    }
}

/// Как панель появляется и исчезает.
enum AnimationStyle: String, CaseIterable {
    /// Пружина с лёгким перелётом — обычный режим.
    case spring
    /// Без движения: панель просто появляется и исчезает. Для слабого железа
    /// и для тех, кого укачивает.
    case none

    var title: String {
        switch self {
        case .spring: return "Пружинная (с перелётом)"
        case .none: return "Без анимации"
        }
    }

    var shortTitle: String {
        switch self {
        case .spring: return "Плавная"
        case .none: return "Без анимации"
        }
    }
}

/// Где именно появляется панель.
enum PanelPlacement: String, CaseIterable {
    /// От самой кромки экрана, поверх строки меню — как в Cyclop.
    case screenTop
    /// Сразу под строкой меню, не перекрывая её.
    case belowMenuBar

    var title: String {
        switch self {
        case .screenTop: return "От самой кромки экрана (поверх строки меню)"
        case .belowMenuBar: return "Сразу под строкой меню"
        }
    }

    var shortTitle: String {
        switch self {
        case .screenTop: return "В самом верху экрана"
        case .belowMenuBar: return "Под строкой меню"
        }
    }
}

/// Состояние интерфейса, общее для панели, меню и окна настроек.
final class AppState: ObservableObject {
    @Published var selectedTab: PanelTab = .clipboard
    @Published var isPinned: Bool = false
    @Published var isEditingText: Bool = false
    @Published var toast: String?
    /// Реагировать ли на наведение. Приватный сеттер: выключить наведение
    /// можно только тогда, когда приложение остаётся доступным другим путём.
    @Published private(set) var hoverEnabled: Bool = true

    /// Показывать ли иконку в строке меню.
    @Published private(set) var showMenuBarIcon: Bool = true

    /// Как вкладка «Приложения» показывает запущенные приложения.
    @Published private(set) var appsDisplayMode: AppsDisplayMode = .all

    /// Открыто ли сейчас окно настроек. Нужно панели: она не должна снимать
    /// активацию приложения, пока на экране чужое окно, которому нужен фокус.
    var isSettingsVisible: Bool = false

    /// Ширина и высота невидимой зоны наведения в верхнем центре экрана.
    @Published var hotspotWidth: CGFloat = 180
    @Published var hotspotHeight: CGFloat = 24

    @Published var placement: PanelPlacement = .screenTop
    /// Ширина панели. Нужна шапке, чтобы решить, помещаются ли подписи вкладок.
    /// Считать это по фактическому layout нельзя: поле поиска во вкладке
    /// «Буфер» перетягивало ширину на себя, и шапка сжималась только там.
    @Published var panelWidth: CGFloat = 760
    @Published var animationStyle: AnimationStyle = .spring

    /// Ставит PanelController.
    var onRequestHide: (() -> Void)?
    var onRequestActivation: (() -> Void)?
    var onPinChanged: ((Bool) -> Void)?
    var onPlacementChanged: (() -> Void)?
    var onAnimationStyleChanged: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onMenuBarIconChanged: ((Bool) -> Void)?

    private let defaults: UserDefaults
    private var toastTimer: Timer?

    private enum Key {
        static let hoverEnabled = "hoverEnabled"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let appsDisplayMode = "appsDisplayMode"
        static let placement = "panelPlacement"
        static let animationStyle = "animationStyle"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Key.hoverEnabled) != nil {
            hoverEnabled = defaults.bool(forKey: Key.hoverEnabled)
        }
        if defaults.object(forKey: Key.showMenuBarIcon) != nil {
            showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        }
        if let raw = defaults.string(forKey: Key.appsDisplayMode), let mode = AppsDisplayMode(rawValue: raw) {
            appsDisplayMode = mode
        }
        // Испорченное сочетание из прошлых версий: приложение осталось бы без
        // единого способа открыть настройки.
        if !hoverEnabled && !showMenuBarIcon { showMenuBarIcon = true }
        if let raw = defaults.string(forKey: Key.placement), let value = PanelPlacement(rawValue: raw) {
            placement = value
        }
        if let raw = defaults.string(forKey: Key.animationStyle), let value = AnimationStyle(rawValue: raw) {
            animationStyle = value
        }
    }

    func showToast(_ message: String) {
        toast = message
        toastTimer?.invalidate()
        let timer = Timer(timeInterval: 1.4, repeats: false) { [weak self] _ in
            self?.toast = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        toastTimer = timer
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        onPinChanged?(pinned)
    }

    /// Иконку в строке меню можно спрятать, только если панель открывается
    /// наведением. И наоборот: наведение можно выключить, только если иконка
    /// на месте. Иначе до настроек не добраться вообще.
    var canHideMenuBarIcon: Bool { hoverEnabled }
    var canDisableHover: Bool { showMenuBarIcon }

    func setHoverEnabled(_ enabled: Bool, persist: Bool = true) {
        if !enabled && !showMenuBarIcon { return }
        hoverEnabled = enabled
        if persist { defaults.set(enabled, forKey: Key.hoverEnabled) }
    }

    func setAppsDisplayMode(_ mode: AppsDisplayMode, persist: Bool = true) {
        guard appsDisplayMode != mode else { return }
        appsDisplayMode = mode
        if persist { defaults.set(mode.rawValue, forKey: Key.appsDisplayMode) }
    }

    func setShowMenuBarIcon(_ visible: Bool, persist: Bool = true) {
        if !visible && !hoverEnabled { return }
        guard showMenuBarIcon != visible else { return }
        showMenuBarIcon = visible
        if persist { defaults.set(visible, forKey: Key.showMenuBarIcon) }
        onMenuBarIconChanged?(visible)
    }

    func setPlacement(_ value: PanelPlacement) {
        guard placement != value else { return }
        placement = value
        defaults.set(value.rawValue, forKey: Key.placement)
        onPlacementChanged?()
    }

    func setAnimationStyle(_ value: AnimationStyle) {
        guard animationStyle != value else { return }
        animationStyle = value
        defaults.set(value.rawValue, forKey: Key.animationStyle)
        onAnimationStyleChanged?()
    }

    func requestHide() {
        onRequestHide?()
    }

    func requestActivation() {
        onRequestActivation?()
    }

    func requestSettings() {
        onOpenSettings?()
    }
}
