import AppKit

/// Настраиваемая зона появления панели.
///
/// Координаты хранятся **нормированными** (0…1 относительно кадра экрана,
/// начало — левый нижний угол). Так зона переживает смену разрешения и
/// подключение другого монитора: те же 18% ширины останутся теми же 18%.
struct HotspotArea: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    /// Минимальный размер в точках: полосу меньшего размера невозможно ни
    /// увидеть, ни поймать курсором.
    static let minWidth: CGFloat = 60
    static let minHeight: CGFloat = 10

    /// Заводская зона: полоса по центру верхней кромки.
    static func defaultArea(in screen: NSRect) -> HotspotArea {
        HotspotArea(
            x: 0.5 - 90 / max(1, screen.width),
            y: 1 - 24 / max(1, screen.height),
            width: 180 / max(1, screen.width),
            height: 24 / max(1, screen.height)
        )
    }

    /// Точки на конкретном экране.
    func rect(in screen: NSRect) -> NSRect {
        let frame = screen
        var width = max(Self.minWidth, self.width * frame.width)
        var height = max(Self.minHeight, self.height * frame.height)
        width = min(width, frame.width)
        height = min(height, frame.height)

        var originX = frame.minX + x * frame.width
        var originY = frame.minY + y * frame.height
        originX = min(max(originX, frame.minX), frame.maxX - width)
        originY = min(max(originY, frame.minY), frame.maxY - height)
        return NSRect(x: originX.rounded(), y: originY.rounded(), width: width.rounded(), height: height.rounded())
    }

    /// Обратное преобразование: прямоугольник в точках → нормированная зона.
    static func from(rect: NSRect, in screen: NSRect) -> HotspotArea {
        guard screen.width > 0, screen.height > 0 else {
            return HotspotArea(x: 0, y: 0, width: 0.25, height: 0.02)
        }
        let clampedWidth = min(max(rect.width, minWidth), screen.width)
        let clampedHeight = min(max(rect.height, minHeight), screen.height)
        let originX = min(max(rect.minX, screen.minX), screen.maxX - clampedWidth)
        let originY = min(max(rect.minY, screen.minY), screen.maxY - clampedHeight)
        return HotspotArea(
            x: (originX - screen.minX) / screen.width,
            y: (originY - screen.minY) / screen.height,
            width: clampedWidth / screen.width,
            height: clampedHeight / screen.height
        )
    }
}

/// Откуда выезжает панель. Восемь направлений: четыре стороны и четыре угла.
enum PanelDirection: String, CaseIterable, Codable {
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
    case topLeft

    var title: String {
        switch self {
        case .top: return "сверху вниз"
        case .topRight: return "из правого верхнего угла"
        case .right: return "справа налево"
        case .bottomRight: return "из правого нижнего угла"
        case .bottom: return "снизу вверх"
        case .bottomLeft: return "из левого нижнего угла"
        case .left: return "слева направо"
        case .topLeft: return "из левого верхнего угла"
        }
    }

    var isCorner: Bool {
        switch self {
        case .top, .bottom, .left, .right: return false
        default: return true
        }
    }

    var isVerticalEdge: Bool {
        self == .top || self == .bottom
    }

    /// Направление, в котором панель выезжает (от края к центру экрана).
    var inward: CGVector {
        switch self {
        case .top: return CGVector(dx: 0, dy: -1)
        case .bottom: return CGVector(dx: 0, dy: 1)
        case .left: return CGVector(dx: 1, dy: 0)
        case .right: return CGVector(dx: -1, dy: 0)
        case .topLeft: return CGVector(dx: 1, dy: -1)
        case .topRight: return CGVector(dx: -1, dy: -1)
        case .bottomLeft: return CGVector(dx: 1, dy: 1)
        case .bottomRight: return CGVector(dx: -1, dy: 1)
        }
    }
}

/// Результат расчёта: где панель стоит, где прячется и в какую сторону едет.
struct PanelLayout: Equatable {
    var visible: NSRect
    var hidden: NSRect
    var direction: PanelDirection
}

/// Геометрия выезда. Чистая функция — её проверяют тесты без окон и экранов.
enum PanelGeometry {
    /// Доля размера экрана, попадание в которую считается «у края».
    static let edgeZone: CGFloat = 0.22

    /// Куда смотрит зона появления: ближайшая сторона или угол.
    static func direction(for hotspot: NSRect, in screen: NSRect) -> PanelDirection {
        let centerX = hotspot.midX
        let centerY = hotspot.midY
        let nx = screen.width > 0 ? (centerX - screen.minX) / screen.width : 0.5
        let ny = screen.height > 0 ? (centerY - screen.minY) / screen.height : 0.5

        let nearLeft = nx <= edgeZone
        let nearRight = nx >= 1 - edgeZone
        let nearBottom = ny <= edgeZone
        let nearTop = ny >= 1 - edgeZone

        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        default:
            // Зона в середине экрана: выезжать неоткуда, поэтому берём
            // ближайшую сторону — панель поедет из-за неё.
            let distances: [(PanelDirection, CGFloat)] = [
                (.top, screen.maxY - centerY),
                (.bottom, centerY - screen.minY),
                (.left, centerX - screen.minX),
                (.right, screen.maxX - centerX),
            ]
            return distances.min { $0.1 < $1.1 }?.0 ?? .top
        }
    }

    /// Положение панели и её скрытая точка.
    static func layout(size: NSSize,
                       screen: NSRect,
                       hotspot: NSRect,
                       placement: PanelPlacement,
                       menuBarHeight: CGFloat) -> PanelLayout {
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        let direction = direction(for: hotspot, in: screen)
        let gap: CGFloat = 6

        var visible: NSRect
        switch direction {
        case .top:
            let top = placement == .screenTop ? screen.maxY : screen.maxY - menuBarHeight
            visible = NSRect(x: centredX(hotspot: hotspot, screen: screen, width: width),
                             y: top - height,
                             width: width,
                             height: height)
        case .bottom:
            visible = NSRect(x: centredX(hotspot: hotspot, screen: screen, width: width),
                             y: screen.minY,
                             width: width,
                             height: height)
        case .left:
            visible = NSRect(x: screen.minX,
                             y: centredY(hotspot: hotspot, screen: screen, height: height),
                             width: width,
                             height: height)
        case .right:
            visible = NSRect(x: screen.maxX - width,
                             y: centredY(hotspot: hotspot, screen: screen, height: height),
                             width: width,
                             height: height)
        case .topLeft:
            visible = NSRect(x: screen.minX, y: screen.maxY - height, width: width, height: height)
        case .topRight:
            visible = NSRect(x: screen.maxX - width, y: screen.maxY - height, width: width, height: height)
        case .bottomLeft:
            visible = NSRect(x: screen.minX, y: screen.minY, width: width, height: height)
        case .bottomRight:
            visible = NSRect(x: screen.maxX - width, y: screen.minY, width: width, height: height)
        }

        // Скрытая позиция — та же панель, сдвинутая за край экрана вдоль
        // направления. На угол сдвиг идёт сразу по двум осям, поэтому панель
        // выезжает по диагонали, а не «сначала вбок, потом вниз».
        let inward = direction.inward
        var hidden = visible
        if inward.dx != 0 {
            hidden.origin.x += inward.dx > 0 ? -(width + gap) : (width + gap)
        }
        if inward.dy != 0 {
            hidden.origin.y += inward.dy > 0 ? -(height + gap) : (height + gap)
        }

        return PanelLayout(
            visible: visible.integral,
            hidden: hidden.integral,
            direction: direction
        )
    }

    private static func centredX(hotspot: NSRect, screen: NSRect, width: CGFloat) -> CGFloat {
        clamp(hotspot.midX - width / 2, min: screen.minX, max: screen.maxX - width)
    }

    private static func centredY(hotspot: NSRect, screen: NSRect, height: CGFloat) -> CGFloat {
        clamp(hotspot.midY - height / 2, min: screen.minY, max: screen.maxY - height)
    }

    private static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }
}
