import AppKit
import SwiftUI

/// Окно настроек. Обычное активируемое окно: панель намеренно не забирает
/// фокус, а здесь пользователю нужно печатать и перетаскивать, поэтому
/// приложение активируется на время работы с настройками.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let tabSettings: TabSettings
    private let appState: AppState
    private let translation: TranslationService
    private var didActivate = false

    init(tabSettings: TabSettings, appState: AppState, translation: TranslationService) {
        self.tabSettings = tabSettings
        self.appState = appState
        self.translation = translation
        super.init()
    }

    func show() {
        if window == nil {
            let view = SettingsView(tabSettings: tabSettings, appState: appState, translation: translation)
            let hosting = NSHostingView(rootView: view)
            let size = hosting.fittingSize
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Настройки DynamicBar"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("DynamicBarSettings")
            self.window = window
        }

        guard let window else { return }
        if !didActivate {
            didActivate = true
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        Log.info("settings window opened")
    }

    func windowWillClose(_ notification: Notification) {
        Log.info("settings window closed")
        guard didActivate else { return }
        didActivate = false
        // Возвращаем фокус приложению, в котором пользователь работал.
        NSApp.deactivate()
    }
}
