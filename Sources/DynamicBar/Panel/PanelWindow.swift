import AppKit

/// Borderless, non-activating panel that hosts the DynamicBar UI.
///
/// * `.nonactivatingPanel` → clicking a button never steals focus from the app
///   the user is working in.
/// * `becomesKeyOnlyIfNeeded` → the panel only takes key focus when a text field
///   is clicked (snippet editing), and only after we explicitly activate.
/// * Window level is one below the menu bar (`mainMenu - 1`) so the panel slides
///   out from *under* the menu bar instead of covering it.
final class PanelWindow: NSPanel {
    var onEscape: (() -> Void)?
    var onClickInside: (() -> Void)?

    static var panelLevel: NSWindow.Level {
        NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = PanelWindow.panelLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // Never let AppKit try to restore this window.
        isRestorable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        // 53 == Escape
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onClickInside?()
        super.mouseDown(with: event)
    }
}
