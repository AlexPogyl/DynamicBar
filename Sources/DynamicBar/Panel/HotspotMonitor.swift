import AppKit

/// Detects that the pointer is hovering the invisible strip at the top centre of
/// the screen.
///
/// Design note: we deliberately do **not** create an invisible window over the
/// menu bar. Such a window would sit above (or below) the menu bar and either
/// swallow clicks or never receive mouse-moved events. Instead we observe the
/// global pointer position with an `NSEvent` global monitor (mouse events need no
/// permission) plus a cheap watchdog timer, so menu bar clicks keep working
/// exactly as before when the panel is closed.
final class HotspotMonitor {
    var onMouseMoved: ((NSPoint) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var watchdog: Timer?
    private var globalEventCount = 0
    private var didReportMonitorStatus = false

    /// Watchdog rate — a safety net for the (unlikely) case where the global
    /// monitor delivers nothing; keeps hover latency ≤ one tick even then.
    private let watchdogInterval: TimeInterval = 0.033

    func start() {
        stop()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            guard let self else { return }
            self.globalEventCount += 1
            self.onMouseMoved?(NSEvent.mouseLocation)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.onMouseMoved?(NSEvent.mouseLocation)
            return event
        }

        let timer = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.reportMonitorStatusIfNeeded()
            self.onMouseMoved?(NSEvent.mouseLocation)
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer

        Log.info("hotspot monitor started (global=\(globalMonitor != nil) local=\(localMonitor != nil))")
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        watchdog?.invalidate()
        watchdog = nil
    }

    private func reportMonitorStatusIfNeeded() {
        guard !didReportMonitorStatus else { return }
        didReportMonitorStatus = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            if self.globalEventCount == 0 {
                Log.info("hotspot: no global mouse-moved events yet — the position watchdog drives hover detection (same behaviour, ≤\(Int(self.watchdogInterval * 1000))ms later)")
            } else {
                Log.info("hotspot: global mouse monitor active (\(self.globalEventCount) events seen)")
            }
        }
    }

    var isGlobalMonitorActive: Bool { globalMonitor != nil }
}
