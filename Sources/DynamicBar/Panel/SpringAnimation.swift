import AppKit
import QuartzCore

/// Пружинный аниматор для одного скалярного значения.
///
/// `NSAnimationContext` умеет только кривые Безье, а «яблочное» выезжание
/// панели — это пружина с лёгким перелётом и мягкой посадкой. Здесь она
/// считается численно и отдаётся наружу через `onUpdate`, поэтому окно
/// двигается по-настоящему, а не подменяется анимацией слоя.
///
/// Кадры приходят от `CADisplayLink`, то есть от самого дисплея, и шаг
/// интегрирования берётся из фактического интервала между кадрами. Раньше
/// здесь стоял таймер с фиксированным шагом 1/120: если он срабатывал
/// неравномерно — а на загруженном главном потоке он срабатывает именно так, —
/// движение распадалось на видимые ступеньки и шло с неправильной скоростью.
final class SpringAnimation {
    /// Собственная частота: отклик ≈ 2π/ω.
    private var omega: CGFloat = 19.0
    /// Коэффициент затухания. 1.0 — без перелёта, 0.78 — упругий.
    private var zeta: CGFloat = 0.78

    private var timer: Timer?
    /// Момент последнего шага — по нему сторожевой таймер понимает, жив ли
    /// display link.
    private var lastTickTime: CFTimeInterval = 0
    /// `CADisplayLink` лежит как `AnyObject`: хранимые свойства нельзя
    /// помечать `@available`, а минимальная версия проекта — macOS 13.
    private var displayLinkStorage: AnyObject?
    private weak var displayView: NSView?
    private var lastTimestamp: CFTimeInterval = 0

    private var value: CGFloat = 0
    private var target: CGFloat = 0
    private var velocity: CGFloat = 0
    private var startValue: CGFloat = 0
    private var onUpdate: ((CGFloat, CGFloat) -> Void)?
    private var onComplete: (() -> Void)?

    /// Статистика кадров последнего прогона — по ней видно, ровно ли идёт
    /// движение. Заполняется всегда, стоит почти ничего.
    private(set) var frameCount = 0
    private(set) var minFrameMs: Double = 0
    private(set) var maxFrameMs: Double = 0
    private(set) var totalFrameMs: Double = 0

    var averageFrameMs: Double { frameCount > 0 ? totalFrameMs / Double(frameCount) : 0 }
    var isRunning: Bool {
        timer != nil || displayLinkStorage != nil
    }

    /// Дисплей-линк перестаёт приходить, когда окно полностью уходит за край
    /// экрана — а именно туда панель и уезжает при скрытии. Без сторожа
    /// пружина замирает в последних долях пункта, и завершение не наступает:
    /// окно остаётся «показанным» и не убирается с экрана. Поэтому таймер
    /// работает всегда и подхватывает движение, если линк замолчал.
    private let watchdogInterval: CFTimeInterval = 0.035

    var frameSummary: String {
        guard frameCount > 0 else { return "кадров нет" }
        return String(format: "кадров %d, сред %+.1f мс, мин %.1f, макс %.1f",
                      frameCount, averageFrameMs, minFrameMs, maxFrameMs)
    }

    /// Вид, к дисплею которого привязываются кадры. Без него используется
    /// таймер — например, пока окно ещё не на экране.
    func attach(to view: NSView) {
        displayView = view
    }

    /// `onUpdate` получает текущее значение и нормированный прогресс 0…1.
    func run(from: CGFloat,
             to: CGFloat,
             initialVelocity: CGFloat = 0,
             response: CGFloat = 19.0,
             damping: CGFloat = 0.78,
             onUpdate: @escaping (CGFloat, CGFloat) -> Void,
             onComplete: (() -> Void)? = nil) {
        cancel()
        omega = response
        zeta = damping
        value = from
        startValue = from
        target = to
        velocity = initialVelocity
        self.onUpdate = onUpdate
        self.onComplete = onComplete

        frameCount = 0
        minFrameMs = 0
        maxFrameMs = 0
        totalFrameMs = 0
        lastTimestamp = 0

        startDriver()
        step(dt: 1.0 / 120.0)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        if #available(macOS 14.0, *), let link = displayLinkStorage as? CADisplayLink {
            link.invalidate()
        }
        displayLinkStorage = nil
        onUpdate = nil
        onComplete = nil
    }

    // MARK: - Источник кадров

    private func startDriver() {
        // Сторож есть всегда.
        let watchdog = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        RunLoop.main.add(watchdog, forMode: .common)
        timer = watchdog

        if #available(macOS 14.0, *), let view = displayView, view.window != nil {
            let displayLink = view.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            displayLink.add(to: .main, forMode: .common)
            displayLinkStorage = displayLink
        }
    }

    /// Шаг по фактически прошедшему времени, если дисплей-линк молчит.
    private func watchdogTick() {
        let now = CACurrentMediaTime()
        guard now - lastTickTime >= watchdogInterval else { return }
        let dt = lastTickTime == 0 ? 1.0 / 120.0 : now - lastTickTime
        lastTickTime = now
        step(dt: CGFloat(min(max(dt, 1.0 / 240.0), 1.0 / 30.0)))
    }

    @available(macOS 14.0, *)
    @objc private func displayLinkFired(_ displayLink: CADisplayLink) {
        let now = displayLink.targetTimestamp
        let dt = lastTimestamp == 0 ? 1.0 / 120.0 : now - lastTimestamp
        lastTimestamp = now
        lastTickTime = CACurrentMediaTime()
        // Скачок после паузы не должен разгонять пружину: ограничиваем шаг
        // тридцатью герцами сверху и 240 снизу.
        step(dt: min(max(dt, 1.0 / 240.0), 1.0 / 30.0))
    }

    // MARK: - Интегрирование

    private func step(dt: CGFloat) {
        let ms = Double(dt) * 1000
        frameCount += 1
        totalFrameMs += ms
        if frameCount == 1 || ms < minFrameMs { minFrameMs = ms }
        if ms > maxFrameMs { maxFrameMs = ms }

        let stiffness = omega * omega
        let damping = 2 * zeta * omega
        let acceleration = stiffness * (target - value) - damping * velocity
        velocity += acceleration * dt
        value += velocity * dt

        let span = target - startValue
        let progress = abs(span) > 0.001 ? (value - startValue) / span : 1
        onUpdate?(value, min(max(progress, 0), 1))

        let settled = abs(target - value) < 0.35 && abs(velocity) < 4
        if settled {
            let completion = onComplete
            cancel()
            value = target
            onUpdate?(value, 1)
            completion?()
        }
    }
}
