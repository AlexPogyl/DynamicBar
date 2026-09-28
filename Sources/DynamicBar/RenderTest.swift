import AppKit
import SwiftUI

/// `DynamicBar --rendertest <outDir>`
///
/// Renders the real panel views off-screen to PNG files. This is a development
/// aid: the machine that builds the app may not have Screen Recording permission,
/// but `NSHostingView.cacheDisplay` lets us still *see* the UI and catch layout
/// regressions. Output is written to the given directory.
enum RenderTest {
    static func run(outputDirectory: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let clipboard = ClipboardStore()
        clipboard.add("https://github.com/akalikbergenov/cyclop")
        clipboard.add("swiftc -O -wmo -parse-as-library -o DynamicBar Sources/**/*.swift")
        clipboard.add("Это довольно длинная запись в истории буфера обмена, чтобы проверить, как выглядит предпросмотр в две строки и переносится ли текст.")
        clipboard.add("Привет, мир")
        clipboard.add("https://developer.apple.com/documentation/appkit/nspanel")
        clipboard.add("sk-1234567890abcdef — этот текст лучше не показывать целиком")


        let snippets = SnippetStore()
        let volume = SystemVolume()
        let apps = AppsStore()
        let runningApps = RunningAppsMonitor()
        let translation = TranslationService()
        let notes = NoteStore()
        // Детерминированный пример для рендера.
        notes.notes.forEach { notes.remove($0) }
        for body in [
            "Позвонить в сервис\nЗаписаться на четверг, после 15:00.\nВзять с собой документы на машину.",
            "Идеи для панели\n— показывать погоду на выходных\n— горячая клавиша на ⌥Space",
            "Список покупок\nкофе, овсянка, оливковое масло, лимоны",
        ] {
            let note = notes.add()
            notes.update(note.id, text: body)
        }
        notes.select(notes.notes.first!)
        let nowPlaying = NowPlayingService()
        nowPlaying.applyPreviewSample()
        // ClipboardStore loads persisted history in init; for a deterministic
        // preview we only want the sample rows.
        clipboard.clearEverything()
        clipboard.add("https://github.com/akalikbergenov/cyclop")
        clipboard.add("swiftc -O -wmo -parse-as-library -o DynamicBar Sources/**/*.swift")
        clipboard.add("Это довольно длинная запись в истории буфера обмена, чтобы проверить, как выглядит предпросмотр в две строки и переносится ли текст.")
        clipboard.add("Привет, мир")
        clipboard.add("https://developer.apple.com/documentation/appkit/nspanel")
        clipboard.add("sk-1234567890abcdef — этот текст лучше не показывать целиком")

        // Картинка в истории — чтобы проверить строку с миниатюрой.
        if let png = Self.samplePNG(), let image = NSImage(data: png) {
            let file = "rendertest-sample.png"
            try? png.write(to: AppPaths.imagesDirectory.appendingPathComponent(file))
            clipboard.addImage(fileName: file, width: 480, height: 300, bytes: png.count, digest: "rendertest")
            _ = image
        }

        let appState = AppState()
        let tabSettings = TabSettings(defaults: UserDefaults(suiteName: "com.dynamicbar.rendertest") ?? .standard)
        tabSettings.reset()
        let size = NSSize(width: 760, height: 430)

        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let label = appearance == .darkAqua ? "dark" : "light"
            for tab in PanelTab.allCases {
                appState.selectedTab = tab
                appState.isPinned = (tab == .clipboard)
                let url = directory.appendingPathComponent("panel-\(label)-\(tab.rawValue).png")
                render(
                    root: PanelRootView(appState: appState, clipboard: clipboard, snippets: snippets, notes: notes, apps: apps, runningApps: runningApps, translation: translation, nowPlaying: nowPlaying, volume: volume, tabSettings: tabSettings),
                    size: size,
                    appearance: appearance,
                    to: url
                )
                print("RENDERTEST wrote \(url.path)")
            }
            // snippet editor state
            appState.selectedTab = .snippets
            appState.isEditingText = true
            let url = directory.appendingPathComponent("panel-\(label)-snippets-editing.png")
            renderEditor(size: size, appearance: appearance, to: url, appState: appState, snippets: snippets, notes: notes, clipboard: clipboard, volume: volume, apps: apps, runningApps: runningApps, translation: translation, tabSettings: tabSettings)
            print("RENDERTEST wrote \(url.path)")

            // Music tab with no readable metadata — the state most users will see
            // on macOS 26, where the system hides the track name.
            appState.isEditingText = false
            appState.selectedTab = .music
            let emptyMusicService = NowPlayingService()
            emptyMusicService.setDetectedPlayerForPreview("Яндекс Музыка")
            let emptyURL = directory.appendingPathComponent("panel-\(label)-music-nometadata.png")
            render(
                root: PanelRootView(appState: appState, clipboard: clipboard, snippets: snippets, notes: notes, apps: apps, runningApps: runningApps, translation: translation, nowPlaying: emptyMusicService, volume: volume, tabSettings: tabSettings),
                size: size,
                appearance: appearance,
                to: emptyURL
            )
            print("RENDERTEST wrote \(emptyURL.path)")
        }

        // Окно настроек — отдельно, у него своя ширина.
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let label = appearance == .darkAqua ? "dark" : "light"
            let url = directory.appendingPathComponent("settings-\(label).png")
            render(
                root: SettingsView(tabSettings: tabSettings, appState: appState, translation: translation),
                size: NSSize(width: 460, height: 520),
                appearance: appearance,
                to: url
            )
            print("RENDERTEST wrote \(url.path)")
        }

        print("RENDERTEST OK")
    }

    private static func renderEditor(size: NSSize, appearance: NSAppearance.Name, to url: URL, appState: AppState, snippets: SnippetStore, notes: NoteStore, clipboard: ClipboardStore, volume: SystemVolume, apps: AppsStore, runningApps: RunningAppsMonitor, translation: TranslationService, tabSettings: TabSettings) {
        render(
            root: PanelRootView(appState: appState, clipboard: clipboard, snippets: snippets, notes: notes, apps: apps, runningApps: runningApps, translation: translation, nowPlaying: NowPlayingService(), volume: volume, tabSettings: tabSettings),
            size: size,
            appearance: appearance,
            to: url
        )
    }

    /// Небольшая картинка для рендер-теста.
    private static func samplePNG() -> Data? {
        let size = NSSize(width: 480, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemIndigo.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSRect(x: 60, y: 60, width: 360, height: 180).fill()
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSRect(x: 150, y: 120, width: 180, height: 60).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func render<Content: View>(root: Content, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        guard let image = image(root: root, size: size, appearance: appearance) else { return }
        write(image, to: url)
    }

    static func write(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            print("RENDERTEST ERROR: png encoding failed")
            return
        }
        try? data.write(to: url)
    }

    /// Растеризует вид в изображение — общая часть для рендер-теста и для
    /// скриншотов README.
    static func image<Content: View>(root: Content, size: NSSize, appearance: NSAppearance.Name) -> NSImage? {
        let frame = NSRect(origin: .zero, size: size)

        // Dark/light backdrop stands in for what the vibrancy layer blurs behind
        // the panel on screen.
        let backdrop = NSView(frame: frame)
        backdrop.wantsLayer = true
        backdrop.appearance = NSAppearance(named: appearance)
        backdrop.layer?.backgroundColor = (appearance == .darkAqua
            ? NSColor(calibratedWhite: 0.35, alpha: 1).cgColor
            : NSColor(calibratedWhite: 0.72, alpha: 1).cgColor)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = frame
        hosting.appearance = NSAppearance(named: appearance)
        backdrop.addSubview(hosting)

        backdrop.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        backdrop.layoutSubtreeIfNeeded()

        guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: frame) else {
            print("RENDERTEST ERROR: could not create bitmap rep")
            return nil
        }
        backdrop.cacheDisplay(in: frame, to: rep)

        let output = NSImage(size: size)
        output.addRepresentation(rep)
        return output
    }
}

extension NowPlayingService {
    /// Preview-only helper used by `--rendertest` so the Music tab can be
    /// rendered with representative content.
    func applyPreviewSample() {
        previewSet(
            title: "Bohemian Rhapsody",
            artist: "Queen",
            album: "A Night at the Opera",
            isPlaying: true,
            elapsed: 132,
            duration: 354,
            source: "Apple Music"
        )
    }

    private func previewSet(title: String, artist: String, album: String, isPlaying: Bool, elapsed: Double, duration: Double, source: String) {
        setPreviewValues(title: title, artist: artist, album: album, isPlaying: isPlaying, elapsed: elapsed, duration: duration, source: source)
    }
}
