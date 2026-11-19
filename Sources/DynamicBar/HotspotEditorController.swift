import AppKit
import SwiftUI

/// Редактор зоны появления: серая полоса поверх всего, которую можно таскать
/// по экрану и растягивать за ручки.
///
/// Полоса — это отдельное окно ровно того же размера, что и зона: двигая окно,
/// мы двигаем зону, поэтому нет расхождения между картинкой и попаданием
/// курсора. Ручки нарисованы внутри окна, чтобы у самого края экрана они
/// оставались видимыми.
final class HotspotEditorController: NSObject {
    private weak var appState: AppState?
    private var editorPanel: EditorPanel?
    private var editorView: HotspotEditorView?
    private var hudPanel: NSPanel?
    private var keyMonitor: Any?
    private var screen: NSScreen = NSScreen.main ?? NSScreen.screens[0]
    private var originalArea: HotspotArea?

    func begin(appState: AppState) {
        guard editorPanel == nil else { return }
        self.appState = appState
        self.screen = PanelController.activeScreen()
        self.originalArea = appState.hotspotArea

        let area = appState.hotspotArea ?? HotspotArea.defaultArea(in: screen.frame)
        let rect = area.rect(in: screen.frame)

        let panel = EditorPanel(contentRect: rect)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false

        let view = HotspotEditorView(frame: NSRect(origin: .zero, size: rect.size))
        view.autoresizingMask = [.width, .height]
        view.onFrameChange = { [weak self] rect in
            self?.apply(rect: rect)
        }
        view.onFinish = { [weak self] in
            self?.finish()
        }
        panel.contentView = view
        panel.orderFrontRegardless()

        editorPanel = panel
        editorView = view
        appState.isEditingHotspot = true

        showHUD(for: rect)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.finish()
                return nil
            }
            return event
        }

        Log.info("hotspot editor: opened at \(rect)")
    }

    /// Применяет прямоугольник в координатах экрана к состоянию.
    private func apply(rect: NSRect) {
        guard let appState else { return }
        let area = HotspotArea.from(rect: rect, in: screen.frame)
        appState.setHotspotArea(area)
        updateHUD(for: rect)
    }

    private func showHUD(for rect: NSRect) {
        let hud = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hud.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hud.isReleasedWhenClosed = false

        let root = HotspotEditorHUD(
            onDone: { [weak self] in self?.finish() },
            onReset: { [weak self] in self?.reset() },
            onCancel: { [weak self] in self?.cancel() }
        )
        hud.contentView = NSHostingView(rootView: root)
        hud.orderFrontRegardless()
        hudPanel = hud
        positionHUD(near: rect)
    }

    private func positionHUD(near rect: NSRect) {
        guard let hud = hudPanel else { return }
        let size = hud.frame.size
        let frame = screen.frame
        var originX = rect.midX - size.width / 2
        originX = min(max(originX, frame.minX + 8), frame.maxX - size.width - 8)
        var originY = rect.minY - size.height - 10
        if originY < frame.minY + 8 {
            originY = rect.maxY + 10
        }
        hud.setFrameOrigin(NSPoint(x: originX.rounded(), y: originY.rounded()))
    }

    private func updateHUD(for rect: NSRect) {
        positionHUD(near: rect)
    }

    private func reset() {
        guard let appState else { return }
        appState.resetHotspotArea()
        let area = HotspotArea.defaultArea(in: screen.frame)
        let rect = area.rect(in: screen.frame)
        editorPanel?.setFrame(rect, display: true)
        updateHUD(for: rect)
    }

    private func cancel() {
        if let originalArea {
            appState?.setHotspotArea(originalArea)
        } else {
            appState?.resetHotspotArea()
        }
        close()
    }

    /// Для диагностики: закрыть редактор, вернув исходную зону.
    func cancelForTesting() {
        cancel()
    }

    private func finish() {
        close()
    }

    private func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        editorPanel?.orderOut(nil)
        editorPanel?.close()
        editorPanel = nil
        editorView = nil
        hudPanel?.orderOut(nil)
        hudPanel?.close()
        hudPanel = nil
        appState?.isEditingHotspot = false
        Log.info("hotspot editor: closed")
    }
}

/// Панель редактора должна уметь становиться key, иначе Esc до неё не дойдёт.
final class EditorPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
    }

    required init?(coder: NSCoder) {
        fatalError("EditorPanel не создаётся из архива")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Полоса и ручки. Окно редактора совпадает с зоной, поэтому всё рисуется
/// внутри его границ.
final class HotspotEditorView: NSView {
    var onFrameChange: ((NSRect) -> Void)?
    var onFinish: (() -> Void)?

    private enum DragMode {
        case move
        case resize(Handle)
    }

    private enum Handle: Int, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private var dragMode: DragMode?
    private var startMouse: NSPoint = .zero
    private var startFrame: NSRect = .zero
    private let handleSide: CGFloat = 7
    private let handleInset: CGFloat = 5
    private let minimumSize = NSSize(width: HotspotArea.minWidth, height: HotspotArea.minHeight)

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(6, bounds.height / 2)
        let body = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(white: 0.55, alpha: 0.5).setFill()
        body.fill()
        NSColor(white: 1, alpha: 0.9).setStroke()
        body.lineWidth = 1
        body.stroke()

        NSColor(white: 1, alpha: 0.95).setFill()
        for rect in handleRects() {
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }

        if bounds.height >= 22, bounds.width >= 90 {
            let text = "\(Int(bounds.width)) × \(Int(bounds.height))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
            (text as NSString).draw(at: origin, withAttributes: attributes)
        }
    }

    private func handleRects() -> [NSRect] {
        let w = bounds.width
        let h = bounds.height
        let side = handleSide
        func rect(_ x: CGFloat, _ y: CGFloat) -> NSRect {
            NSRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
        }
        return [
            rect(handleInset, h - handleInset),
            rect(w / 2, h - handleInset),
            rect(w - handleInset, h - handleInset),
            rect(w - handleInset, h / 2),
            rect(w - handleInset, handleInset),
            rect(w / 2, handleInset),
            rect(handleInset, handleInset),
            rect(handleInset, h / 2),
        ]
    }

    private func handle(at point: NSPoint) -> Handle? {
        for (index, rect) in handleRects().enumerated() {
            if rect.insetBy(dx: -3, dy: -3).contains(point) {
                return Handle(rawValue: index)
            }
        }
        return nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startFrame = window?.frame ?? .zero
        let local = convert(event.locationInWindow, from: nil)
        if let handle = handle(at: local) {
            dragMode = .resize(handle)
        } else {
            dragMode = .move
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragMode, let window, let screen = window.screen else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        var frame = startFrame

        switch dragMode {
        case .move:
            frame.origin.x += dx
            frame.origin.y += dy
        case .resize(let handle):
            var minX = frame.minX, maxX = frame.maxX
            var minY = frame.minY, maxY = frame.maxY
            switch handle {
            case .topLeft: minX += dx; maxY += dy
            case .top: maxY += dy
            case .topRight: maxX += dx; maxY += dy
            case .right: maxX += dx
            case .bottomRight: maxX += dx; minY += dy
            case .bottom: minY += dy
            case .bottomLeft: minX += dx; minY += dy
            case .left: minX += dx
            }
            let width = max(minimumSize.width, maxX - minX)
            let height = max(minimumSize.height, maxY - minY)
            // Если тянут за левую/нижнюю ручку, противоположный край стоит на месте.
            if minX > maxX - minimumSize.width { minX = maxX - minimumSize.width }
            if minY > maxY - minimumSize.height { minY = maxY - minimumSize.height }
            frame = NSRect(x: minX, y: minY, width: width, height: height)
        }

        // Не выпускаем полосу за экран: иначе она станет недоступной.
        let limit = screen.frame
        frame.size.width = min(frame.width, limit.width)
        frame.size.height = min(frame.height, limit.height)
        frame.origin.x = min(max(frame.origin.x, limit.minX), limit.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, limit.minY), limit.maxY - frame.height)

        window.setFrame(frame, display: true)
        onFrameChange?(frame)
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
        NSCursor.openHand.set()
        if let window {
            onFrameChange?(window.frame)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(); return }
        super.keyDown(with: event)
    }
}

/// Подсказка под полосой с кнопками.
private struct HotspotEditorHUD: View {
    let onDone: () -> Void
    let onReset: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Зона появления панели")
                    .font(.system(size: 11, weight: .semibold))
                Text("Тащите полосу за середину, тяните за ручки, чтобы изменить размер")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Сброс", action: onReset)
                .controlSize(.small)
            Button("Отмена", action: onCancel)
                .controlSize(.small)
            Button("Готово", action: onDone)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
    }
}
