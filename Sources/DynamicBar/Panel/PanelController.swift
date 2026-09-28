import AppKit
import SwiftUI

/// Owns the slide-out panel: geometry, show/hide state machine, hover handling
/// and the keyboard-focus dance needed for snippet editing.
final class PanelController {
    private let panel: PanelWindow
    private let appState: AppState
    private let nowPlaying: NowPlayingService

    private(set) var isVisible = false
    private var isAnimating = false
    /// Скрытие уже идёт. Без этого флага автомат наведения успевал
    /// запланировать второе скрытие: `isVisible` становится false только по
    /// завершении анимации, а курсор всё это время остаётся снаружи.
    private var isHiding = false
    private var didActivateApp = false
    /// Timestamp of the last genuine click inside the panel. Used as a guard so
    /// that stray focus changes can never steal keyboard focus from the app the
    /// user is actually working in.
    private var lastUserClickAt: Date = .distantPast
    private var clickMonitor: Any?

    private var showWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?

    /// Движение окна считает пружина, а не кривая Безье: у Apple выезжающая
    /// панель всегда чуть перелетает и мягко садится.
    private let spring = SpringAnimation()

    /// Delay before the panel appears once the pointer touches the hotspot.
    private let showDelay: TimeInterval = 0.12
    /// Grace period before hiding once the pointer leaves.
    private let hideDelay: TimeInterval = 0.30
    private let animationDuration: TimeInterval = 0.22
    /// Extra slack around the panel so tiny pointer excursions don't hide it.
    private let hideMargin: CGFloat = 10

    init(appState: AppState, rootView: AnyView, nowPlaying: NowPlayingService) {
        self.appState = appState
        self.nowPlaying = nowPlaying

        let screen = PanelController.activeScreen()
        let geometry = PanelController.geometry(for: screen, placement: appState.placement)

        panel = PanelWindow(contentRect: geometry.visible)
        // `.hudWindow` vibrancy is always dark, so pin the whole panel to the dark
        // appearance — otherwise light-mode SwiftUI text would render black on a
        // dark blurred background.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = PanelController.level(for: appState.placement)
        panel.onEscape = { [weak self] in
            guard let self else { return }
            // Esc leaves snippet editing first, and only then closes the panel.
            if self.appState.isEditingText {
                self.appState.isEditingText = false
                self.appState.showToast("Редактирование отменено")
            } else {
                self.hide(reason: "escape")
            }
        }
        panel.onClickInside = { [weak self] in
            self?.lastUserClickAt = Date()
            self?.cancelHide()
        }

        // A local monitor is the reliable way to see clicks destined for our own
        // window hierarchy (NSWindow.mouseDown is not always reached once a view
        // handles the event).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            self.lastUserClickAt = Date()
            self.cancelHide()

            // Панель неактивна намеренно, но клик по кнопке в неключевом окне
            // AppKit может израсходовать на то, чтобы сделать окно ключевым, —
            // и действие не сработает с первого раза. Делаем окно ключевым до
            // отправки события, тогда клик всегда доходит до кнопки.
            if !self.panel.isKeyWindow {
                Log.debug("panel: click while not key — making key first")
                self.panel.makeKey()
            }
            return event
        }

        let bounds = NSRect(origin: .zero, size: geometry.visible.size)

        let container = NSView(frame: bounds)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true

        // Frosted "HUD" background behind the SwiftUI content.
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        container.addSubview(blur)

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        container.addSubview(hosting)

        panel.contentView = container
        spring.attach(to: container)

        appState.onRequestHide = { [weak self] in self?.hide(reason: "ui") }
        appState.onRequestActivation = { [weak self] in self?.activateForEditing() }
        appState.onPlacementChanged = { [weak self] in self?.applyPlacement() }
        appState.onAnimationStyleChanged = { [weak self] in
            guard let self else { return }
            self.spring.cancel()
            self.isAnimating = false
        }

        appState.panelWidth = geometry.visible.width
        Log.info("panel geometry: visible=\(geometry.visible) hidden=\(geometry.hidden) screen=\(screen.frame)")
    }

    // MARK: - Geometry

    static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first!
    }

    static func panelSize(for screen: NSScreen) -> NSSize {
        let frame = screen.frame
        let width = min(760, max(520, frame.width - 160))
        let available = screen.visibleFrame.height
        let height = min(430, max(280, available - 80))
        return NSSize(width: width, height: height)
    }

    /// Верхняя кромка панели. В режиме `.screenTop` она совпадает с верхом
    /// экрана и панель перекрывает строку меню; в режиме `.belowMenuBar`
    /// начинается сразу под ней. Скрытая позиция в обоих случаях выше экрана,
    /// поэтому панель буквально выезжает из-за верхней кромки.
    static func geometry(for screen: NSScreen, placement: PanelPlacement = .screenTop) -> (visible: NSRect, hidden: NSRect) {
        let size = panelSize(for: screen)
        let menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let topY: CGFloat
        switch placement {
        case .screenTop: topY = screen.frame.maxY
        case .belowMenuBar: topY = screen.frame.maxY - menuBarHeight
        }
        let originX = screen.frame.midX - size.width / 2
        let visible = NSRect(x: originX.rounded(), y: (topY - size.height).rounded(), width: size.width, height: size.height)
        // На два пункта выше экрана: между кадрами не должно мелькать ребро.
        let hidden = NSRect(x: visible.origin.x, y: screen.frame.maxY + 2, width: size.width, height: size.height)
        return (visible, hidden)
    }

    /// Уровень окна. В режиме `.screenTop` панель должна быть строго выше
    /// строки меню, иначе её верхние 30 pt окажутся под ней: строка меню живёт
    /// на 24–25, поэтому берём 26. Выпадающие меню (101+) и системные
    /// оповещения остаются сверху — панель их не перекрывает.
    static func level(for placement: PanelPlacement) -> NSWindow.Level {
        switch placement {
        case .screenTop: return NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        case .belowMenuBar: return NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        }
    }

    /// The invisible hover zone: a strip centred on the top edge of the screen.
    static func hotspotRect(for screen: NSScreen, width: CGFloat, height: CGFloat) -> NSRect {
        let menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let effectiveHeight = max(height, menuBarHeight)
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - effectiveHeight,
            width: width,
            height: effectiveHeight
        )
    }

    /// Exposed for `--showtest` diagnostics.
    var panelFrame: NSRect { panel.frame }

    /// Статистика кадров последней анимации — для `--animtest`.
    var animationFrameSummary: String { spring.frameSummary }

    var hotspotRect: NSRect {
        let screen = PanelController.activeScreen()
        return PanelController.hotspotRect(
            for: screen,
            width: appState.hotspotWidth,
            height: appState.hotspotHeight
        )
    }

    // MARK: - Hover state machine

    /// Called for every observed mouse position (global monitor + safety poll).
    func handleMouse(at location: NSPoint) {
        // Hover interaction switched off in the menu bar: never auto-show and
        // never auto-hide — the panel is then purely manual.
        guard appState.hoverEnabled else {
            cancelShow()
            cancelHide()
            return
        }

        let inHotspot = hotspotRect.contains(location)

        if !isVisible {
            if inHotspot {
                scheduleShow()
            } else {
                cancelShow()
            }
            return
        }

        // Visible: decide whether the pointer is still "engaged".
        if appState.isPinned || appState.isEditingText {
            cancelHide()
            return
        }

        let panelZone = panel.frame.insetBy(dx: -hideMargin, dy: -hideMargin)
        if inHotspot || panelZone.contains(location) {
            cancelHide()
        } else {
            scheduleHide()
        }
    }

    private func scheduleShow() {
        guard showWorkItem == nil, !isVisible, !isAnimating else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.showWorkItem = nil
            guard let self else { return }
            // Re-check: the pointer may have left during the dwell time.
            guard self.hotspotRect.contains(NSEvent.mouseLocation) else { return }
            self.show(reason: "hover")
        }
        showWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: item)
    }

    private func cancelShow() {
        showWorkItem?.cancel()
        showWorkItem = nil
    }

    private func scheduleHide() {
        guard hideWorkItem == nil, !isHiding else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.hideWorkItem = nil
            guard let self else { return }
            guard !self.appState.isPinned, !self.appState.isEditingText else { return }
            let location = NSEvent.mouseLocation
            let panelZone = self.panel.frame.insetBy(dx: -self.hideMargin, dy: -self.hideMargin)
            guard !panelZone.contains(location), !self.hotspotRect.contains(location) else { return }
            self.hide(reason: "hover-out")
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: item)
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    // MARK: - Show / hide

    func toggle(reason: String) {
        if isVisible {
            hide(reason: reason)
        } else {
            show(reason: reason)
        }
    }

    func show(reason: String) {
        cancelShow()
        cancelHide()
        guard !isVisible || isAnimating else { return }

        let screen = PanelController.activeScreen()
        let geometry = PanelController.geometry(for: screen, placement: appState.placement)

        if !isVisible {
            panel.setFrame(geometry.hidden, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            isVisible = true
        }
        // Показ отменяет незавершённое скрытие.
        isHiding = false

        if appState.animationStyle == .none {
            spring.cancel()
            isAnimating = false
            panel.setFrame(geometry.visible, display: true)
            panel.alphaValue = 1
            panel.invalidateShadow()
            nowPlaying.setActive(true)
            Log.info("panel shown (\(reason)) без анимации frame=\(geometry.visible)")
            NotificationCenter.default.post(name: .dynamicBarPanelDidShow, object: nil)
            return
        }

        isAnimating = true
        let startY = panel.frame.origin.y
        spring.run(
            from: startY,
            to: geometry.visible.origin.y,
            response: 19,
            damping: 0.78
        ) { [weak self] y, progress in
            guard let self else { return }
            self.panel.setFrameOrigin(NSPoint(x: geometry.visible.origin.x, y: y))
            // Прозрачность догоняет первую часть пути, иначе панель «проявляется»
            // уже доехав.
            self.panel.alphaValue = min(1, progress * 1.8)
        } onComplete: { [weak self] in
            guard let self else { return }
            self.panel.setFrame(geometry.visible, display: true)
            self.panel.alphaValue = 1
            self.isAnimating = false
            self.panel.invalidateShadow()
            // Свежие данные о треке — как только панель открылась.
            self.nowPlaying.setActive(true)
        }

        Log.info("panel shown (\(reason)) frame=\(geometry.visible)")
        NotificationCenter.default.post(name: .dynamicBarPanelDidShow, object: nil)
    }

    func hide(reason: String) {
        cancelHide()
        cancelShow()
        guard isVisible, !isHiding else { return }
        isHiding = true

        let screen = panel.screen ?? PanelController.activeScreen()
        let geometry = PanelController.geometry(for: screen, placement: appState.placement)

        if appState.animationStyle == .none {
            spring.cancel()
            isAnimating = false
            isVisible = false
            isHiding = false
            panel.orderOut(nil)
            panel.alphaValue = 0
            endEditingFocusIfNeeded()
            if appState.isEditingText { appState.isEditingText = false }
            Log.info("panel hidden (\(reason)) без анимации")
            NotificationCenter.default.post(name: .dynamicBarPanelDidHide, object: nil)
            return
        }

        isAnimating = true
        spring.run(
            from: panel.frame.origin.y,
            to: geometry.hidden.origin.y,
            response: 22,
            damping: 1.0 // уход без перелёта: подпрыгивать на выходе нечему
        ) { [weak self] y, progress in
            guard let self else { return }
            self.panel.setFrameOrigin(NSPoint(x: geometry.visible.origin.x, y: y))
            self.panel.alphaValue = max(0, 1 - progress * 1.6)
        } onComplete: { [weak self] in
            guard let self else { return }
            self.isAnimating = false
            self.isVisible = false
            self.isHiding = false
            self.panel.orderOut(nil)
            self.panel.alphaValue = 0
            self.endEditingFocusIfNeeded()
        }

        if appState.isEditingText {
            appState.isEditingText = false
        }
        Log.info("panel hidden (\(reason))")
        NotificationCenter.default.post(name: .dynamicBarPanelDidHide, object: nil)
    }

    // MARK: - Размещение

    /// Пользователь переключил «в самом верху экрана» ↔ «под строкой меню».
    /// Уровень окна и позиция применяются сразу: если панель открыта, она
    /// должна переместиться, а не ждать следующего показа.
    func applyPlacement() {
        panel.level = PanelController.level(for: appState.placement)
        guard isVisible else { return }
        let screen = panel.screen ?? PanelController.activeScreen()
        let geometry = PanelController.geometry(for: screen, placement: appState.placement)
        spring.cancel()
        panel.setFrame(geometry.visible, display: true)
        panel.alphaValue = 1
        isAnimating = false
        isHiding = false
        appState.panelWidth = geometry.visible.width
        Log.info("panel placement applied: \(appState.placement) frame=\(geometry.visible)")
    }

    // MARK: - Focus handling for text entry

    /// Snippet/search text entry needs real keyboard focus, which for an
    /// `.accessory` app means briefly activating it.
    ///
    /// Guarded by a recent genuine click: merely hovering the hotspot must never
    /// pull focus away from whatever the user is typing in.
    func activateForEditing() {
        guard isVisible else { return }
        let sinceClick = Date().timeIntervalSince(lastUserClickAt)
        guard sinceClick < 1.5 else {
            Log.debug("activation skipped — no recent click inside the panel (\(String(format: "%.1f", sinceClick))s)")
            return
        }
        guard !didActivateApp else { return }
        didActivateApp = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        Log.debug("panel activated for text entry (after click)")
    }

    func endEditingFocusIfNeeded() {
        guard didActivateApp else { return }
        didActivateApp = false
        NSApp.deactivate()
        Log.debug("panel released focus")
    }
}

extension Notification.Name {
    static let dynamicBarPanelDidShow = Notification.Name("DynamicBarPanelDidShow")
    static let dynamicBarPanelDidHide = Notification.Name("DynamicBarPanelDidHide")
}
