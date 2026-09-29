import AppKit
import SwiftUI

/// `DynamicBar --screenshot <dir>`
///
/// Отдельный режим для картинок в README. От `--rendertest` отличается тем,
/// что **все** данные демонстрационные: список приложений берётся из системных
/// иконок, обложка альбома рисуется градиентом, а названия трека и источника
/// нейтральные. В кадр не должно попасть ничего личного.
enum ScreenshotTest {
    static func run(outputDirectory: String) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let appState = AppState()
        let tabSettings = TabSettings(defaults: UserDefaults(suiteName: "com.dynamicbar.screenshottest") ?? .standard)
        tabSettings.reset()
        let clipboard = ClipboardStore()
        clipboard.clearEverything()
        for text in [
            "https://github.com/",
            "swiftc -O -wmo -parse-as-library -o DynamicBar Sources/**/*.swift",
            "Съёмка экрана без личных данных: только демонстрационные записи",
        ] {
            clipboard.add(text)
        }
        clipboard.add("Это длинная запись в истории буфера обмена, чтобы показать, как выглядит предпросмотр в две строки и переносится ли текст.")
        clipboard.add("Привет, мир")

        // Картинка в истории — рисуется на месте, ничего чужого.
        if let png = gradientPNG(size: NSSize(width: 480, height: 300)), let image = NSImage(data: png) {
            let file = "demo-image.png"
            try? png.write(to: AppPaths.imagesDirectory.appendingPathComponent(file))
            clipboard.addImage(fileName: file, width: 480, height: 300, bytes: png.count, digest: "demo")
            _ = image
        }

        let snippets = SnippetStore()
        let notes = NoteStore()
        notes.notes.forEach { notes.remove($0) }
        for body in [
            "Идеи для панели\n— показывать погоду\n— горячая клавиша на ⌥Space",
            "Список покупок\nкофе, овсянка, оливковое масло",
        ] {
            let note = notes.add()
            notes.update(note.id, text: body)
        }
        notes.select(notes.notes.first!)

        let apps = AppsStore()
        apps.pinned.forEach { apps.remove($0) }
        apps.addLink("github.com")

        let runningApps = RunningAppsMonitor()
        runningApps.loadPreviewApplications()
        runningApps.loadPreviewSpaces()
        // Для картинки в README показываем самый содержательный режим.
        appState.setAppsDisplayMode(.bySpace, persist: false)

        let translation = TranslationService(defaults: UserDefaults(suiteName: "com.dynamicbar.screenshottest") ?? .standard)
        translation.input = "The panel slides out from the very top of the screen."
        translation.provider = .google

        let volume = SystemVolume()
        let nowPlaying = NowPlayingService()
        nowPlaying.setPreviewValues(title: "Bohemian Rhapsody",
                                    artist: "Queen",
                                    album: "A Night at the Opera",
                                    isPlaying: true,
                                    elapsed: 132,
                                    duration: 354,
                                    source: "Apple Music")
        nowPlaying.setPreviewArtwork(gradientPNG(size: NSSize(width: 300, height: 300)).flatMap(NSImage.init(data:)))

        let size = NSSize(width: 760, height: 430)
        var shots: [PanelTab: NSImage] = [:]

        for tab in PanelTab.allCases {
            appState.selectedTab = tab
            appState.isPinned = (tab == .clipboard)
            guard let image = RenderTest.image(
                root: PanelRootView(appState: appState,
                                    clipboard: clipboard,
                                    snippets: snippets,
                                    notes: notes,
                                    apps: apps,
                                    runningApps: runningApps,
                                    translation: translation,
                                    nowPlaying: nowPlaying,
                                    volume: volume,
                                    tabSettings: tabSettings),
                size: size,
                appearance: .darkAqua
            ) else { continue }
            shots[tab] = image
            RenderTest.write(image, to: directory.appendingPathComponent("panel-\(tab.rawValue).png"))
            print("SCREENSHOT wrote panel-\(tab.rawValue).png")
        }

        // Отдельно — тот же стол в режиме «все», чтобы было видно разницу.
        appState.setAppsDisplayMode(.all, persist: false)
        if let appsAll = RenderTest.image(
            root: PanelRootView(appState: appState,
                                clipboard: clipboard, snippets: snippets, notes: notes,
                                apps: apps, runningApps: runningApps, translation: translation,
                                nowPlaying: nowPlaying, volume: volume, tabSettings: tabSettings),
            size: size,
            appearance: .darkAqua
        ) {
            RenderTest.write(appsAll, to: directory.appendingPathComponent("panel-apps-all.png"))
            print("SCREENSHOT wrote panel-apps-all.png")
        }
        appState.setAppsDisplayMode(.bySpace, persist: false)

        appState.isEditingText = false
        if let settings = RenderTest.image(
            root: SettingsView(tabSettings: tabSettings, appState: appState, translation: translation),
            size: NSSize(width: 460, height: 520),
            appearance: .darkAqua
        ) {
            RenderTest.write(settings, to: directory.appendingPathComponent("settings.png"))
            print("SCREENSHOT wrote settings.png")
        }

        if let preview = compose(shots: shots, size: size) {
            RenderTest.write(preview, to: directory.appendingPathComponent("preview.png"))
            print("SCREENSHOT wrote preview.png (\(Int(preview.size.width))×\(Int(preview.size.height)))")
        }

        print("SCREENSHOT OK")
    }

    // MARK: - Композиция

    /// Собирает четыре вкладки в одну картинку на градиентном фоне — именно её
    /// показываем в README.
    private static func compose(shots: [PanelTab: NSImage], size: NSSize) -> NSImage? {
        let order: [PanelTab] = [.clipboard, .music, .apps, .notes]
        let images = order.compactMap { shots[$0] }
        guard images.count == order.count else { return nil }

        let scale: CGFloat = 0.86
        let tile = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let gap: CGFloat = 26
        let margin: CGFloat = 40
        let canvas = NSSize(width: tile.width * 2 + gap + margin * 2,
                            height: tile.height * 2 + gap + margin * 2)

        let output = NSImage(size: canvas)
        output.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            output.unlockFocus()
            return nil
        }

        // Фон: глубокий сине-серый градиент.
        let colors = [
            NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.08, alpha: 1).cgColor,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: canvas.height),
                                       end: CGPoint(x: 0, y: 0),
                                       options: [])
        }

        for (index, image) in images.enumerated() {
            let column = CGFloat(index % 2)
            let row = CGFloat(index / 2)
            let origin = CGPoint(
                x: margin + column * (tile.width + gap),
                y: margin + (1 - row) * (tile.height + gap)
            )
            let rect = NSRect(origin: origin, size: tile)

            context.saveGState()
            let path = CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil)
            context.addPath(path)
            context.clip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            context.restoreGState()

            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -6), blur: 24,
                              color: NSColor.black.withAlphaComponent(0.55).cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil))
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
            context.setLineWidth(1)
            context.strokePath()
            context.restoreGState()
        }

        output.unlockFocus()
        return output
    }

    /// Градиентная заглушка вместо настоящей обложки альбома.
    ///
    /// Рисуем средствами AppKit (`NSGradient`, `NSBezierPath`), а не через
    /// `NSGraphicsContext.current?.cgContext`: внутри `NSImage.lockFocus()`
    /// этот контекст оказался недоступен, и функция молча возвращала nil —
    /// обложка просто не появлялась.
    private static func gradientPNG(size: NSSize) -> Data? {
        let image = NSImage(size: size)
        image.lockFocus()

        let bounds = NSRect(origin: .zero, size: size)
        NSGradient(starting: .systemIndigo, ending: .systemTeal)?.draw(in: bounds, angle: -45)

        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width * 0.12, y: size.height * 0.18,
                                    width: size.width * 0.30, height: size.height * 0.30)).fill()

        NSColor.black.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width * 0.58, y: size.height * 0.46,
                                    width: size.width * 0.34, height: size.height * 0.34)).fill()

        image.unlockFocus()

        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
