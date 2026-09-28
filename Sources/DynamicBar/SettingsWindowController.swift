import AppKit
import SwiftUI

/// Окно настроек. Обычное активируемое окно: панель намеренно не забирает
/// фокус, а здесь пользователю нужно печатать и перетаскивать, поэтому
/// приложение активируется на время работы с настройками.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
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

    /// Окно ровно вдвое ниже прежнего (то было выше экрана) и никогда не
    /// выходит за пределы видимой области.
    private static var contentSize: NSSize {
        let usable = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        return NSSize(width: 460, height: min(520, max(360, usable - 140)))
    }

    /// Окно не должно вылезать за видимую область: автосохранённая рама могла
    /// остаться от монитора побольше.
    private static func clampToScreen(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        if frame.height > visible.height - 40 { frame.size.height = visible.height - 40 }
        if frame.width > visible.width - 40 { frame.size.width = visible.width - 40 }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame != window.frame {
            window.setFrame(frame, display: false)
            Log.info("settings window: рама приведена к экрану")
        }
    }

    func show() {
        if window == nil {
            let view = SettingsView(tabSettings: tabSettings, appState: appState, translation: translation)
            let hosting = NSHostingView(rootView: view)
            let size = Self.contentSize
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentMinSize = NSSize(width: 420, height: 320)
            window.title = "Настройки DynamicBar"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            // Имя новое намеренно: по старому автосохранению восстанавливалась
            // рама прежней версии — выше экрана, и окно снова становилось
            // длинным, сколько бы мы ни задавали при создании.
            window.setFrameAutosaveName("DynamicBarSettingsCompact")
            Self.clampToScreen(window)
            self.window = window
        }

        guard let window else { return }
        if !didActivate {
            didActivate = true
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        appState.isSettingsVisible = true
        Log.info("settings window opened")
    }

    func windowWillClose(_ notification: Notification) {
        appState.isSettingsVisible = false
        Log.info("settings window closed")
        guard didActivate else { return }
        didActivate = false
        // Возвращаем фокус приложению, в котором пользователь работал.
        NSApp.deactivate()
    }
}
