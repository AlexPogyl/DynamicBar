import AppKit

/// The menu bar extra: show/hide the panel, preferences and quit.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let clipboard: ClipboardStore
    private let snippets: SnippetStore
    private let nowPlaying: NowPlayingService

    var onShowPanel: (() -> Void)?
    var onTogglePanel: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init(appState: AppState, clipboard: ClipboardStore, snippets: SnippetStore, nowPlaying: NowPlayingService) {
        self.appState = appState
        self.clipboard = clipboard
        self.snippets = snippets
        self.nowPlaying = nowPlaying
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = StatusItemController.makeIcon()
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.toolTip = "DynamicBar — наведите курсор на верхний центр экрана"
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        Log.info("status item created (visible=\(statusItem.isVisible))")
    }

    /// Machine-readable description of where the menu bar icon actually lives.
    /// Used by `--showtest` / `scripts/verify.sh` to prove the extra is mounted.
    var statusItemDebugInfo: String {
        guard statusItem.isVisible else { return "not visible" }
        guard let button = statusItem.button else { return "no button" }
        guard let window = button.window else { return "button has no window" }
        let frame = window.frame
        return "visible=true windowFrame=(\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))) image=\(button.image != nil)"
    }

    static func makeIcon() -> NSImage? {
        let candidates = ["menubar.arrow.down.rectangle", "rectangle.topthird.inset.filled", "chevron.down.square", "capsule.bottomhalf.filled"]
        for name in candidates {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "DynamicBar") {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            // Left click: toggle the panel straight away — the fastest path.
            onTogglePanel?()
        }
    }

    private func showContextMenu() {
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Menu

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let showItem = NSMenuItem(title: "Показать панель", action: #selector(showPanel), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let placementItem = NSMenuItem(title: "Где появляется панель", action: nil, keyEquivalent: "")
        let placementMenu = NSMenu()
        for placement in PanelPlacement.allCases {
            let item = NSMenuItem(title: placement.shortTitle, action: #selector(selectPlacement(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = placement.rawValue
            item.state = appState.placement == placement ? .on : .off
            placementMenu.addItem(item)
        }
        placementItem.submenu = placementMenu
        menu.addItem(placementItem)

        let loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)

        let hoverItem = NSMenuItem(title: "Реагировать на наведение сверху", action: #selector(toggleHover), keyEquivalent: "")
        hoverItem.target = self
        hoverItem.state = appState.hoverEnabled ? .on : .off
        menu.addItem(hoverItem)

        menu.addItem(.separator())

        let clipboardInfo = NSMenuItem(title: "История буфера: \(clipboard.items.count) из \(ClipboardStore.maxItems)", action: nil, keyEquivalent: "")
        clipboardInfo.isEnabled = false
        menu.addItem(clipboardInfo)

        let clearItem = NSMenuItem(title: "Очистить историю буфера", action: #selector(clearClipboard), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        let snippetInfo = NSMenuItem(title: "Сниппеты: \(snippets.snippets.count)", action: nil, keyEquivalent: "")
        snippetInfo.isEnabled = false
        menu.addItem(snippetInfo)

        menu.addItem(.separator())

        let logItem = NSMenuItem(title: "Открыть журнал", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        let folderItem = NSMenuItem(title: "Открыть папку данных", action: #selector(openDataFolder), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Actions

    @objc private func showPanel() { onShowPanel?() }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let enable = !LaunchAtLogin.isEnabled
        let ok = LaunchAtLogin.setEnabled(enable)
        sender.state = LaunchAtLogin.isEnabled ? .on : .off
        if !ok {
            Log.error("launch-at-login toggle failed")
        }
    }

    @objc private func toggleHover(_ sender: NSMenuItem) {
        appState.setHoverEnabled(!appState.hoverEnabled)
        sender.state = appState.hoverEnabled ? .on : .off
        Log.info("hover enabled = \(appState.hoverEnabled)")
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func selectPlacement(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let placement = PanelPlacement(rawValue: raw) else { return }
        appState.setPlacement(placement)
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? String) == raw ? .on : .off }
    }

    @objc private func clearClipboard() {
        clipboard.clearAll()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.path))
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.open(AppPaths.supportDirectory)
    }

    @objc private func quit() {
        onQuit?()
    }
}
