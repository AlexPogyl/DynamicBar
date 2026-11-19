import AppKit
import SwiftUI

/// Редактор зоны появления: серая полоса поверх всего, которую можно таскать
/// по экрану и растягивать за ручки.
///
/// Окно редактора **больше полосы** на запас по краям: у зоны 24 × 4 ручки
/// иначе некуда нарисовать и не за что ухватиться. Полоса рисуется внутри
/// окна по своим настоящим координатам, поэтому попадание курсора в неё
/// совпадает с картинкой.
final class HotspotEditorController: NSObject {
    /// Запас вокруг полосы для ручек, в точках.
    static let padding: CGFloat = 12

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
        let strip = area.rect(in: screen.frame)
        let windowFrame = Self.paddedFrame(for: strip, in: screen.frame)

        let panel = EditorPanel(contentRect: windowFrame)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false

        let view = HotspotEditorView(frame: NSRect(origin: .zero, size: windowFrame.size))
        view.autoresizingMask = [.width, .height]
        view.strip = strip
        view.onStripChange = { [weak self] rect in
            self?.apply(strip: rect)
        }
        view.onFinish = { [weak self] in
            self?.finish()
        }
        panel.contentView = view
        panel.orderFrontRegardless()

        editorPanel = panel
        editorView = view
        appState.isEditingHotspot = true

        showHUD(for: strip)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.finish()
                return nil
            }
            return event
        }

        Log.info("hotspot editor: opened at \(strip) (window \(windowFrame))")
    }

    /// Окно вокруг полосы: запас по краям, но всегда в пределах экрана.
    static func paddedFrame(for strip: NSRect, in screen: NSRect) -> NSRect {
        var frame = strip.insetBy(dx: -padding, dy: -padding)
        frame.size.width = min(frame.width, screen.width)
        frame.size.height = min(frame.height, screen.height)
        frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - frame.height)
        return frame.integral
    }

    /// Применяет полосу в координатах экрана к состоянию и переставляет окно.
    private func apply(strip: NSRect) {
        guard let appState, let panel = editorPanel, let view = editorView else { return }
        let frame = Self.paddedFrame(for: strip, in: screen.frame)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        view.strip = strip
        view.needsDisplay = true
        appState.setHotspotArea(HotspotArea.from(rect: strip, in: screen.frame))
        positionHUD(near: strip)
    }

    private func showHUD(for strip: NSRect) {
        let hud = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 58),
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
        positionHUD(near: strip)
    }

    private func positionHUD(near strip: NSRect) {
        guard let hud = hudPanel else { return }
        let size = hud.frame.size
        let frame = screen.frame

        var originX = strip.midX - size.width / 2
        originX = min(max(originX, frame.minX + 8), frame.maxX - size.width - 8)

        // Снизу места больше, но если полоса у нижней кромки — подсказка сверху.
        var originY = strip.minY - size.height - Self.padding - 8
        if originY < frame.minY + 8 {
            originY = strip.maxY + Self.padding + 8
        }
        if originY + size.height > frame.maxY - 8 {
            originY = frame.minY + 8
        }
        hud.setFrameOrigin(NSPoint(x: originX.rounded(), y: originY.rounded()))
    }

    private func reset() {
        guard let appState else { return }
        appState.resetHotspotArea()
        let strip = HotspotArea.defaultArea(in: screen.frame).rect(in: screen.frame)
        apply(strip: strip)
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

/// Полоса, ручки и перетаскивание.
///
/// `strip` хранится в координатах экрана — так его проще и рисовать, и
/// сравнивать с границами экрана. В координаты вида он переводится через
/// рамку окна, которая всё время следует за полосой.
final class HotspotEditorView: NSView {
    var onStripChange: ((NSRect) -> Void)?
    var onFinish: (() -> Void)?

    var strip: NSRect = .zero {
        didSet { needsDisplay = true }
    }

    private enum DragMode {
        case move
        case resize(Handle)
    }

    private enum Handle: Int, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private var dragMode: DragMode?
    private var startMouse: NSPoint = .zero
    private var startStrip: NSRect = .zero
    private let minimumSize = NSSize(width: HotspotArea.minWidth,
                                    height: HotspotArea.minHeight)

    override var acceptsFirstResponder: Bool { true }

    private var stripInView: NSRect {
        guard let window else { return strip }
        return NSRect(
            x: strip.minX - window.frame.minX,
            y: strip.minY - window.frame.minY,
            width: strip.width,
            height: strip.height
        )
    }

    /// Сторона ручки: на крошечной полосе она не должна её перекрывать.
    private var handleSide: CGFloat {
        let byHeight = max(5, min(9, strip.height * 0.6))
        let byWidth = max(5, min(9, strip.width * 0.25))
        return min(9, max(5, min(byHeight, byWidth)))
    }

    // MARK: - Рисование

    override func draw(_ dirtyRect: NSRect) {
        let rect = stripInView
        guard rect.width > 0, rect.height > 0 else { return }

        let radius = min(4, rect.height / 2)
        let body = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius,
                                yRadius: radius)
        NSColor(white: 0.55, alpha: 0.55).setFill()
        body.fill()
        NSColor(white: 1, alpha: 0.95).setStroke()
        body.lineWidth = 1
        body.stroke()

        NSColor(white: 1, alpha: 0.95).setFill()
        for handle in handleRects(in: rect) {
            NSBezierPath(roundedRect: handle, xRadius: 1.5, yRadius: 1.5).fill()
        }

        if rect.height >= 20, rect.width >= 90 {
            let text = "\(Int(rect.width)) × \(Int(rect.height))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            (text as NSString).draw(at: origin, withAttributes: attributes)
        }
    }

    /// Восемь ручек по углам и серединам сторон. Они стоят **на** границе
    /// полосы и потому попадают в запас окна, а не обрезаются.
    private func handleRects(in rect: NSRect) -> [NSRect] {
        let side = handleSide
        func box(_ x: CGFloat, _ y: CGFloat) -> NSRect {
            NSRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
        }
        return [
            box(rect.minX, rect.maxY),
            box(rect.midX, rect.maxY),
            box(rect.maxX, rect.maxY),
            box(rect.maxX, rect.midY),
            box(rect.maxX, rect.minY),
            box(rect.midX, rect.minY),
            box(rect.minX, rect.minY),
            box(rect.minX, rect.midY),
        ]
    }

    private func handle(at point: NSPoint) -> Handle? {
        let rect = stripInView
        for (index, box) in handleRects(in: rect).enumerated() {
            // Хватаем с запасом: на 4-точечной полосе иначе не попасть.
            if box.insetBy(dx: -6, dy: -6).contains(point) {
                return Handle(rawValue: index)
            }
        }
        return nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    // MARK: - Мышь

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startStrip = strip
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
        var strip = startStrip

        switch dragMode {
        case .move:
            strip.origin.x += dx
            strip.origin.y += dy
        case .resize(let handle):
            var minX = strip.minX, maxX = strip.maxX
            var minY = strip.minY, maxY = strip.maxY
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
            if maxX - minX < minimumSize.width {
                if handle == .topLeft || handle == .bottomLeft || handle == .left {
                    minX = maxX - minimumSize.width
                } else {
                    maxX = minX + minimumSize.width
                }
            }
            if maxY - minY < minimumSize.height {
                if handle == .topLeft || handle == .top || handle == .topRight {
                    maxY = minY + minimumSize.height
                } else {
                    minY = maxY - minimumSize.height
                }
            }
            strip = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        // Не выпускаем полосу за экран: иначе она станет недоступной.
        let limit = screen.frame
        strip.size.width = min(max(strip.width, minimumSize.width), limit.width)
        strip.size.height = min(max(strip.height, minimumSize.height), limit.height)
        strip.origin.x = min(max(strip.origin.x, limit.minX), limit.maxX - strip.width)
        strip.origin.y = min(max(strip.origin.y, limit.minY), limit.maxY - strip.height)

        self.strip = strip.integral
        onStripChange?(self.strip)
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
        NSCursor.openHand.set()
        onStripChange?(strip)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(); return }
        super.keyDown(with: event)
    }
}

/// Подсказка рядом с полосой.
private struct HotspotEditorHUD: View {
    let onDone: () -> Void
    let onReset: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Зона появления панели")
                    .font(.system(size: 11, weight: .semibold))
                Text("Тащите полосу за любое место, ручки по краям меняют размер")
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
        .frame(width: 360)
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
