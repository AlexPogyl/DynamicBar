import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let showTest: Bool
    private let settingsTest: Bool
    private let animationTest: Bool
    private let activationTest: Bool

    private let appState = AppState()
    private let clipboard = ClipboardStore()
    private let snippets = SnippetStore()
    private let notes = NoteStore()
    private let apps = AppsStore()
    private let runningApps = RunningAppsMonitor()
    private let translation = TranslationService()
    private let nowPlaying = NowPlayingService()
    private let volume = SystemVolume()
    private let tabSettings = TabSettings()
    private var settingsWindow: SettingsWindowController?

    private var panelController: PanelController!
    private var hotspot: HotspotMonitor!
    private var statusItemController: StatusItemController!

    init(showTest: Bool, settingsTest: Bool = false, animationTest: Bool = false, activationTest: Bool = false) {
        self.showTest = showTest
        self.settingsTest = settingsTest
        self.animationTest = animationTest
        self.activationTest = activationTest
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("=== DynamicBar launched (macOS \(ProcessInfo.processInfo.operatingSystemVersionString), pid \(ProcessInfo.processInfo.processIdentifier)) ===")

        guard !anotherInstanceIsRunning() else {
            Log.error("another DynamicBar instance is already running — exiting")
            NSApp.terminate(nil)
            return
        }

        let rootView = AnyView(
            PanelRootView(
                appState: appState,
                clipboard: clipboard,
                snippets: snippets,
                notes: notes,
                apps: apps,
                runningApps: runningApps,
                translation: translation,
                nowPlaying: nowPlaying,
                volume: volume,
                tabSettings: tabSettings
            )
        )

        panelController = PanelController(appState: appState, rootView: rootView, nowPlaying: nowPlaying)

        hotspot = HotspotMonitor()
        hotspot.onMouseMoved = { [weak self] location in
            self?.panelController.handleMouse(at: location)
        }
        hotspot.start()

        statusItemController = StatusItemController(
            appState: appState,
            clipboard: clipboard,
            snippets: snippets,
            nowPlaying: nowPlaying
        )
        statusItemController.onTogglePanel = { [weak self] in
            self?.panelController.toggle(reason: "status-item")
        }
        statusItemController.onShowPanel = { [weak self] in
            self?.panelController.show(reason: "status-item")
        }
        settingsWindow = SettingsWindowController(tabSettings: tabSettings, appState: appState, translation: translation)
        let openSettings: () -> Void = { [weak self] in
            guard let self else { return }
            self.settingsWindow?.show()
        }
        statusItemController.onOpenSettings = openSettings
        appState.onOpenSettings = openSettings
        statusItemController.onQuit = {
            Log.info("quit requested from menu bar")
            NSApp.terminate(nil)
        }

        if let first = tabSettings.firstVisibleTab, !tabSettings.orderedVisibleTabs.contains(appState.selectedTab) {
            appState.selectedTab = first
        }

        clipboard.start()
        nowPlaying.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        if showTest {
            runShowTest()
        }
        if settingsTest {
            runSettingsTest()
        }
        if animationTest {
            runAnimationTest()
        }
        if activationTest {
            runActivationTest()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("=== DynamicBar terminating ===")
        clipboard.stop()
        nowPlaying.stop()
        hotspot?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func screenParametersChanged() {
        Log.info("screen parameters changed — panel geometry will be recomputed on next show")
    }

    // MARK: - Helpers

    private func anotherInstanceIsRunning() -> Bool {
        if ProcessInfo.processInfo.environment["DYNAMICBAR_ALLOW_MULTI"] == "1" { return false }
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        return !others.isEmpty
    }

    /// `--showtest`: exercise the real show/hide code paths and print results,
    /// so the build can be verified without a human watching the screen.
    ///
    /// It also dumps the window server's view of our windows (bounds, layer) —
    /// that is external, OS-level proof that the panel really is on screen at the
    /// right place, one layer *below* the menu bar, and completely gone when hidden.
    private func runShowTest() {
        Log.info("show test: starting")
        // Hover is switched off for the duration so the panel cannot be
        // auto-hidden just because the pointer happens to be elsewhere.
        appState.hoverEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            print("SHOWTEST visible-before=\(self.panelController.isVisible)")
            print("SHOWTEST status-item=\(self.statusItemController.statusItemDebugInfo)")
            self.dumpWindows(tag: "before")
            self.panelController.show(reason: "showtest")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                print("SHOWTEST visible-after-show=\(self.panelController.isVisible)")
                print("SHOWTEST panel-frame=\(self.panelController.panelFrame)")
                print("SHOWTEST hotspot=\(self.panelController.hotspotRect)")
                self.dumpWindows(tag: "shown")
                print("SHOWTEST clipboard-items=\(self.clipboard.items.count)")
                print("SHOWTEST snippets=\(self.snippets.snippets.count)")
                print("SHOWTEST media-framework=\(self.nowPlaying.frameworkAvailable)")
                print("SHOWTEST media-track=\(self.nowPlaying.hasTrack) title=\(self.nowPlaying.title)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self else { return }
                    self.panelController.hide(reason: "showtest")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self else { return }
                        print("SHOWTEST visible-after-hide=\(self.panelController.isVisible)")
                        self.dumpWindows(tag: "hidden")
                        print("SHOWTEST OK")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    /// `--animtest`: измерить кадры анимации. Позволяет судить о плавности
    /// числом, а не на глаз: ровное движение — это стабильный интервал кадров.
    private func runAnimationTest() {
        appState.hoverEnabled = false
        let style = appState.animationStyle
        print("ANIMTEST стиль=\(style.rawValue)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.panelController.show(reason: "animtest")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                print("ANIMTEST показ: \(self.panelController.animationFrameSummary)")
                self.panelController.hide(reason: "animtest")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self else { return }
                    print("ANIMTEST скрытие: \(self.panelController.animationFrameSummary)")
                    print("ANIMTEST OK")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// `--activationtest`: выяснить, какая стратегия выводит чужое приложение
    /// на передний план из неактивного процесса.
    ///
    /// Перед каждой стратегией цель обязательно уводится назад, иначе проверка
    /// ничего не значит: если цель и так впереди, «сработает» что угодно.
    /// Цели задаются переменными ACTIVATION_TARGET и ACTIVATION_RESET.
    /// `--activationtest`: выяснить, какая стратегия выводит чужое приложение
    /// на передний план из неактивного процесса.
    ///
    /// Перед каждой стратегией цель обязательно уводится назад, иначе проверка
    /// ничего не значит: если цель и так впереди, «сработает» что угодно.
    /// `ACTIVATION_HIDE_TARGET=1` дополнительно прячет цель — так проверяется
    /// случай свёрнутого или скрытого окна, ради которого всё и затевалось.
    private func runActivationTest() {
        appState.hoverEnabled = false

        let environment = ProcessInfo.processInfo.environment
        let resetBundle = environment["ACTIVATION_RESET"] ?? "com.apple.finder"
        // Цель по умолчанию выбираем сами: тест не должен зависеть от того,
        // какое именно приложение открыто у пользователя.
        let targetBundle = environment["ACTIVATION_TARGET"] ?? Self.pickActivationTarget(excluding: resetBundle) ?? "com.apple.finder"
        let hideFirst = environment["ACTIVATION_HIDE_TARGET"] == "1"

        func running(_ bundleID: String) -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { $0.bundleURL != nil }
        }

        guard let target = running(targetBundle), let resetApp = running(resetBundle) else {
            print("ACTIVATIONTEST нужны обе цели: \(targetBundle)=\(running(targetBundle) != nil) \(resetBundle)=\(running(resetBundle) != nil)")
            print("ACTIVATIONTEST OK")
            NSApp.terminate(nil)
            return
        }

        print("ACTIVATIONTEST цель: \(target.localizedName ?? targetBundle), сброс: \(resetApp.localizedName ?? resetBundle), прятать цель: \(hideFirst)")
        print("ACTIVATIONTEST наш процесс активен: \(NSApp.isActive)")

        func front() -> NSRunningApplication? { NSWorkspace.shared.frontmostApplication }
        func isFront(_ app: NSRunningApplication) -> Bool {
            front()?.processIdentifier == app.processIdentifier
        }

        func openApp(_ app: NSRunningApplication) {
            guard let url = app.bundleURL else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        }

        func resetToStartState(_ done: @escaping (Bool) -> Void) {
            openApp(resetApp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let ok = isFront(resetApp)
                print("ACTIVATIONTEST   сброс: впереди \(front()?.localizedName ?? "?") \(ok ? "ок" : "НЕ УДАЛСЯ")")
                done(ok)
            }
        }

        let steps: [(String, () -> Void)] = [
            ("activate(options:)", { target.activate(options: [.activateAllWindows]) }),
            ("AppActivator.bringToFront (как в панели)", {
                AppActivator.bringToFront(target, reason: "activationtest")
            }),
        ]

        var index = 0
        func runNext() {
            guard index < steps.count else {
                openApp(resetApp)
                print("ACTIVATIONTEST OK")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
                return
            }
            let (label, action) = steps[index]
            index += 1

            resetToStartState { resetOK in
                guard resetOK else {
                    print("ACTIVATIONTEST \(label) → пропущено, сброс не удался")
                    runNext()
                    return
                }

                func performStep() {
                    action()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                        let success = isFront(target)
                        let hiddenNote = hideFirst ? ", цель скрыта: \(target.isHidden)" : ""
                        print("ACTIVATIONTEST \(label) → \(success ? "СРАБОТАЛО" : "не сработало") (впереди \(front()?.localizedName ?? "?")\(hiddenNote))")
                        runNext()
                    }
                }

                if hideFirst {
                    target.hide()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { performStep() }
                } else {
                    performStep()
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { runNext() }
    }


    /// Первое подходящее запущенное приложение, кроме исключённого.
    private static func pickActivationTarget(excluding bundleID: String) -> String? {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .first {
                $0.activationPolicy == .regular
                    && $0.bundleURL != nil
                    && $0.bundleIdentifier != bundleID
                    && $0.bundleIdentifier != own
            }?
            .bundleIdentifier
    }

    /// `--settingstest`: открыть окно настроек и убедиться глазами window-сервера,
    /// что оно действительно появилось на экране.
    private func runSettingsTest() {
        appState.hoverEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.settingsWindow?.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                let windows = self.onScreenWindows()
                let settings = windows.first { $0.layer == 0 && $0.width > 300 }
                if let settings {
                    print("SETTINGSTEST window=ok bounds=(\(Int(settings.x)),\(Int(settings.y)) \(Int(settings.width))x\(Int(settings.height)))")
                } else {
                    print("SETTINGSTEST window=missing (нашлось \(windows.count) окон)")
                }
                print("SETTINGSTEST tabs=\(self.tabSettings.orderedVisibleTabs.map(\.rawValue).joined(separator: ","))")
                print("SETTINGSTEST OK")
                NSApp.terminate(nil)
            }
        }
    }

    private struct WindowInfo {
        let layer: Int
        let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
    }

    private func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        return list.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int, pid == myPID else { return nil }
            let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            return WindowInfo(
                layer: entry[kCGWindowLayer as String] as? Int ?? -1,
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            )
        }
    }

    /// Print the window server's record for every on-screen window we own.
    private func dumpWindows(tag: String) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            print("SHOWTEST windows[\(tag)]: unavailable")
            return
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var ours = 0
        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int, pid == Int(myPID) else { continue }
            ours += 1
            let layer = entry[kCGWindowLayer as String] as? Int ?? -1
            let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let x = Int(bounds["X"] ?? 0), y = Int(bounds["Y"] ?? 0)
            let w = Int(bounds["Width"] ?? 0), h = Int(bounds["Height"] ?? 0)
            let onScreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
            print("SHOWTEST window[\(tag)] layer=\(layer) bounds=(\(x),\(y) \(w)x\(h)) onscreen=\(onScreen)")
        }
        if ours == 0 {
            print("SHOWTEST window[\(tag)] none")
        }
        // What sits at menu bar level right now (proves the menu bar is above us).
        let above = list.compactMap { entry -> (Int, String)? in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer >= 24 else { return nil }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? "?"
            return (layer, owner)
        }
        if let top = above.max(by: { $0.0 < $1.0 }) {
            print("SHOWTEST menubar-layer[\(tag)] \(top.0) owner=\(top.1)")
        }
    }
}
