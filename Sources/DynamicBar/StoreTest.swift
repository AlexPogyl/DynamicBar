import AppKit
import Foundation

/// `DynamicBar --storetest`
///
/// Headless verification of the clipboard + snippet logic, including the privacy
/// rules. Runs against a throwaway data directory so a real user history is never
/// touched, and restores whatever was on the pasteboard before the test.
enum StoreTest {
    private static var failures = 0

    static func run() {
        // Isolate storage before anything touches AppPaths.
        let sandbox = NSTemporaryDirectory() + "dynamicbar-storetest-\(UUID().uuidString)"
        setenv("DYNAMICBAR_DATA_DIR", sandbox, 1)
        defer { try? FileManager.default.removeItem(atPath: sandbox) }

        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)

        print("DynamicBar store test (sandbox: \(sandbox))")

        let clipboard = ClipboardStore()
        clipboard.start()

        // 1 — concealed (password manager) content must never be recorded.
        writePasteboard([.string: "SUPER-SECRET-PASSWORD"], extraTypes: ["org.nspasteboard.ConcealedType"])
        pump(1.0)
        check("concealed pasteboard item is skipped", clipboard.items.isEmpty, "items=\(clipboard.items.count)")

        // 2 — transient content must be skipped too.
        writePasteboard([.string: "transient-value"], extraTypes: ["org.nspasteboard.TransientType"])
        pump(1.0)
        check("transient pasteboard item is skipped", clipboard.items.isEmpty, "items=\(clipboard.items.count)")

        // 3 — ordinary text is captured.
        writePasteboard([.string: "hello dynamicbar"])
        pump(1.0)
        check("plain text is captured", clipboard.items.count == 1, "items=\(clipboard.items.count)")
        check("captured content matches", clipboard.items.first?.text == "hello dynamicbar", "got=\(clipboard.items.first?.text ?? "nil")")

        // 4 — duplicates move to the top instead of being stored twice.
        writePasteboard([.string: "second entry"])
        pump(1.0)
        writePasteboard([.string: "hello dynamicbar"])
        pump(1.0)
        check("duplicates are not stored twice", clipboard.items.count == 2, "items=\(clipboard.items.count)")
        check("duplicate is promoted to the top", clipboard.items.first?.text == "hello dynamicbar", "top=\(clipboard.items.first?.text ?? "nil")")

        // 5 — copy-back puts content on the pasteboard without re-recording it.
        let toCopy = clipboard.items.first { $0.text == "second entry" }!
        clipboard.copyToPasteboard(toCopy)
        pump(1.0)
        check("copy-back writes the pasteboard", pasteboard.string(forType: .string) == "second entry", "pb=\(pasteboard.string(forType: .string) ?? "nil")")
        check("copy-back does not duplicate history", clipboard.items.count == 2, "items=\(clipboard.items.count)")
        check("copy-back promotes the item", clipboard.items.first?.text == "second entry", "top=\(clipboard.items.first?.text ?? "nil")")

        // 6 — history is capped at 40.
        for index in 0..<60 {
            clipboard.add("capped entry \(index)")
        }
        check("history capped at \(ClipboardStore.maxItems)", clipboard.items.count == ClipboardStore.maxItems, "items=\(clipboard.items.count)")

        // 7 — pinning survives "clear all".
        let pinned = clipboard.items[3]
        clipboard.togglePin(pinned)
        clipboard.clearAll()
        check("clear all keeps pinned entries", clipboard.items.count == 1 && clipboard.items[0].id == pinned.id, "items=\(clipboard.items.count)")

        // 8 — persistence round-trip.
        clipboard.add("persisted value")
        pump(0.6)
        let reloaded = ClipboardStore()
        check("history persists to disk", reloaded.items.contains { $0.text == "persisted value" }, "reloaded=\(reloaded.items.count)")

        // 9 — изображения в истории.
        let testImage = Self.makeTestImage(width: 64, height: 48)
        pasteboard.clearContents()
        pasteboard.writeObjects([testImage])
        pump(1.2)

        guard let imageItem = clipboard.items.first, imageItem.isImage else {
            check("картинка попала в историю", false, "первая запись: \(clipboard.items.first.map { $0.isImage ? "image" : "text" } ?? "нет")")
            clipboard.stop()
            print("")
            print("STORETEST FAILED (\(failures) check(s))")
            exit(1)
        }
        check("картинка попала в историю", true)
        // На Retina-экране 64 pt превращаются в 128 px: NSImage хранит размер
        // в точках, а в буфере лежат пиксели.
        let retinaScale = Int(NSScreen.main?.backingScaleFactor ?? 1)
        check("размеры картинки записаны в пикселях",
              imageItem.imageWidth == 64 * retinaScale && imageItem.imageHeight == 48 * retinaScale,
              "got \(imageItem.imageWidth ?? -1)x\(imageItem.imageHeight ?? -1), ожидалось \(64 * retinaScale)x\(48 * retinaScale)")
        check("у картинки есть файл на диске",
              imageItem.imageFile.map { FileManager.default.fileExists(atPath: AppPaths.imagesDirectory.appendingPathComponent($0).path) } ?? false)
        check("миниатюра читается", clipboard.thumbnail(for: imageItem) != nil)

        let imagesBefore = clipboard.items.filter(\.isImage).count
        pasteboard.clearContents()
        pasteboard.writeObjects([Self.makeTestImage(width: 64, height: 48)])
        pump(1.2)
        check("повторная копия картинки не дублируется",
              clipboard.items.filter(\.isImage).count == imagesBefore,
              "было \(imagesBefore), стало \(clipboard.items.filter(\.isImage).count)")

        pasteboard.clearContents()
        pasteboard.setString("текст после картинки", forType: .string)
        pump(1.2)
        let imageToCopy = clipboard.items.first { $0.isImage }!
        clipboard.copyToPasteboard(imageToCopy)
        pump(0.6)
        let copiedTypes = Set((pasteboard.types ?? []).map(\.rawValue))
        check("картинка кладётся обратно в буфер",
              copiedTypes.contains("public.tiff") || copiedTypes.contains("public.png"),
              "типы: \(copiedTypes.sorted().joined(separator: ", "))")

        let fileToCheck = imageToCopy.imageFile!
        clipboard.remove(imageToCopy)
        pump(1.0)
        check("удаление записи убирает и файл картинки",
              !FileManager.default.fileExists(atPath: AppPaths.imagesDirectory.appendingPathComponent(fileToCheck).path))

        // Совместимость: запись старого формата (без kind) должна читаться как текст.
        let legacyJSON = """
        [{"id":"\(UUID().uuidString)","text":"старая запись","date":\(Date().timeIntervalSince1970),"isPinned":false}]
        """
        let legacyURL = AppPaths.file("clipboard.json")
        try? legacyJSON.data(using: .utf8)?.write(to: legacyURL)
        let legacyStore = ClipboardStore()
        check("запись старого формата читается как текст",
              legacyStore.items.first?.kind == .text && legacyStore.items.first?.text == "старая запись",
              "получилось: \(legacyStore.items.first.map { "\($0.kind) \($0.text)" } ?? "пусто")")

        // 10 — snippets.
        let snippets = SnippetStore()
        let before = snippets.snippets.count
        snippets.add(title: "Test snippet", body: "body-value-42")
        check("snippet added", snippets.snippets.count == before + 1, "count=\(snippets.snippets.count)")
        check("snippet title stored", snippets.snippets.first?.title == "Test snippet", "title=\(snippets.snippets.first?.title ?? "nil")")

        let added = snippets.snippets.first!
        snippets.update(added, title: "Renamed", body: "body-value-43")
        check("snippet updated", snippets.snippets.first?.body == "body-value-43", "body=\(snippets.snippets.first?.body ?? "nil")")

        snippets.remove(snippets.snippets.first!)
        check("snippet removed", snippets.snippets.count == before, "count=\(snippets.snippets.count)")

        let reloadedSnippets = SnippetStore()
        check("snippets load from disk", reloadedSnippets.snippets.count == before, "count=\(reloadedSnippets.snippets.count)")

        // 11 — порядок и видимость вкладок.
        let suiteName = "com.dynamicbar.storetest"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let suite = UserDefaults(suiteName: suiteName)!
        var tabs = TabSettings(defaults: suite)
        check("все вкладки видимы по умолчанию", tabs.orderedVisibleTabs.count == PanelTab.allCases.count,
              "visible=\(tabs.orderedVisibleTabs.count)")
        check("порядок по умолчанию совпадает с объявленным", tabs.orderedVisibleTabs == PanelTab.allCases,
              "\(tabs.orderedVisibleTabs.map(\.rawValue))")

        tabs.move(PanelTab.music, to: 0)
        check("вкладка перемещается в начало", tabs.orderedVisibleTabs.first == .music,
              "\(tabs.orderedVisibleTabs.map(\.rawValue))")
        check("перемещение не теряет вкладки", tabs.orderedVisibleTabs.count == PanelTab.allCases.count,
              "visible=\(tabs.orderedVisibleTabs.count)")
        check("выше первой строки не пускает", !tabs.canMove(.music, by: -1))
        if let lastID = tabs.entries.last?.id, let lastTab = PanelTab(rawValue: lastID) {
            check("ниже последней строки не пускает", !tabs.canMove(lastTab, by: 1))
        }

        // Ожидаемый порядок считаем сами: тест не должен зависеть от того,
        // сколько вкладок объявлено в приложении.
        var expected = tabs.orderedVisibleTabs
        if let from = expected.firstIndex(of: .clipboard) {
            let moved = expected.remove(at: from)
            expected.insert(moved, at: min(2, expected.count))
        }
        tabs.move(PanelTab.clipboard, to: 2)
        check("перетаскивание ставит вкладку на нужную позицию",
              tabs.orderedVisibleTabs == expected,
              "получилось \(tabs.orderedVisibleTabs.map(\.rawValue)), ожидалось \(expected.map(\.rawValue))")
        tabs.move(PanelTab.music, to: 99)
        check("позиция за пределами списка прижимается к концу",
              tabs.orderedVisibleTabs.last == .music,
              "\(tabs.orderedVisibleTabs.map(\.rawValue))")
        tabs.move(PanelTab.music, to: -5)
        check("отрицательная позиция прижимается к началу",
              tabs.orderedVisibleTabs.first == .music,
              "\(tabs.orderedVisibleTabs.map(\.rawValue))")

        tabs.setVisible(false, for: .snippets)
        check("скрытая вкладка исчезает из шапки", !tabs.orderedVisibleTabs.contains(.snippets),
              "\(tabs.orderedVisibleTabs.map(\.rawValue))")
        check("скрытая вкладка остаётся в настройках", tabs.entries.count == PanelTab.allCases.count,
              "entries=\(tabs.entries.count)")

        let stillVisible = tabs.orderedVisibleTabs
        for tab in stillVisible { tabs.setVisible(false, for: tab) }
        check("последнюю видимую вкладку скрыть нельзя", tabs.orderedVisibleTabs.count == 1,
              "visible=\(tabs.orderedVisibleTabs.count)")

        let reloadedTabs = TabSettings(defaults: suite)
        check("порядок и видимость переживают перезапуск",
              reloadedTabs.orderedVisibleTabs == tabs.orderedVisibleTabs,
              "\(reloadedTabs.orderedVisibleTabs.map(\.rawValue))")

        tabs.reset()
        check("сброс возвращает все вкладки", tabs.orderedVisibleTabs == PanelTab.allCases,
              "\(tabs.orderedVisibleTabs.map(\.rawValue))")
        UserDefaults.standard.removePersistentDomain(forName: suiteName)

        // 12 — заметки.
        let emptyNotes = NoteStore()
        emptyNotes.notes.forEach { emptyNotes.remove($0) }
        check("хранилище заметок очищается", emptyNotes.notes.isEmpty, "count=\(emptyNotes.notes.count)")

        let first = emptyNotes.add()
        check("новая заметка создаётся и выбирается",
              emptyNotes.notes.count == 1 && emptyNotes.selectedID == first.id)
        check("новая заметка пуста", emptyNotes.selected?.isEmpty == true)

        emptyNotes.update(first.id, text: "Позвонить в сервис\nЗаписаться на четверг")
        check("текст заметки сохраняется", emptyNotes.selected?.text.contains("четверг") == true)
        check("заголовок берётся из первой строки", emptyNotes.selected?.title == "Позвонить в сервис",
              "title=\(emptyNotes.selected?.title ?? "nil")")
        check("предпросмотр берёт остальные строки", emptyNotes.selected?.preview == "Записаться на четверг",
              "preview=\(emptyNotes.selected?.preview ?? "nil")")

        let second = emptyNotes.add()
        emptyNotes.update(second.id, text: "Вторая заметка")
        check("правка поднимает заметку наверх", emptyNotes.notes.first?.id == second.id,
              "первая: \(emptyNotes.notes.first?.title ?? "nil")")

        emptyNotes.update(second.id, text: "Вторая заметка")
        check("повторная запись того же текста ничего не ломает", emptyNotes.notes.count == 2)

        // Сохранение заметок асинхронное — даём очереди записать файл.
        pump(0.8)
        let reloadedNotes = NoteStore()
        check("заметки переживают перезапуск",
              reloadedNotes.notes.count == 2 && reloadedNotes.notes.contains { $0.text.contains("четверг") },
              "count=\(reloadedNotes.notes.count)")

        emptyNotes.remove(second)
        check("удаление заметки переключает выделение",
              emptyNotes.notes.count == 1 && emptyNotes.selectedID == first.id,
              "selected=\(emptyNotes.selectedID?.uuidString.prefix(8) ?? "nil")")

        let blank = emptyNotes.add()
        _ = blank
        emptyNotes.remove(emptyNotes.notes.first { $0.id == blank.id }!)
        check("после удаления пустой заметки остаётся одна", emptyNotes.notes.count == 1,
              "count=\(emptyNotes.notes.count)")

        // 13 — вкладка «Приложения».
        let apps = AppsStore()
        apps.pinned.forEach { apps.remove($0) }
        check("хранилище закреплённых пусто", apps.pinned.isEmpty, "count=\(apps.pinned.count)")

        let monitor = RunningAppsMonitor()
        monitor.refresh()
        check("запущенные приложения находятся", !monitor.applications.isEmpty,
              "count=\(monitor.applications.count)")
        check("среди них нет самого DynamicBar",
              !monitor.applications.contains { $0.bundleIdentifier == Bundle.main.bundleIdentifier })
        check("только обычные приложения (без фоновых агентов)",
              monitor.applications.allSatisfy { $0.activationPolicy == .regular })

        if let sample = monitor.applications.first, let sampleID = sample.bundleIdentifier {
            apps.pin(sample)
            check("приложение закрепляется", apps.isPinned(bundleID: sampleID), "pinned=\(apps.pinned.count)")
            apps.pin(sample)
            check("повторное закрепление не дублирует", apps.pinned.count == 1, "pinned=\(apps.pinned.count)")
            check("иконка закреплённого приложения доступна", apps.icon(for: apps.pinned[0]) != nil)
            check("запущенное приложение находится по элементу",
                  apps.runningApplication(for: apps.pinned[0]) != nil)
        }

        check("ссылка без схемы нормализуется", apps.addLink("example.com"))
        check("схема добавлена", apps.pinned.last?.url == "https://example.com",
              "url=\(apps.pinned.last?.url ?? "nil")")
        check("мусор вместо ссылки отклоняется", !apps.addLink("не ссылка вовсе"))

        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dynamicbar-appstest.txt")
        try? "тест".write(to: tempFile, atomically: true, encoding: .utf8)
        check("файл добавляется", apps.addFile(tempFile))
        check("несуществующий файл отклоняется",
              !apps.addFile(URL(fileURLWithPath: "/nope/\(UUID().uuidString)")))
        try? FileManager.default.removeItem(at: tempFile)

        let pinnedCount = apps.pinned.count
        pump(0.8)
        let reloadedApps = AppsStore()
        check("закреплённое переживает перезапуск", reloadedApps.pinned.count == pinnedCount,
              "было \(pinnedCount), стало \(reloadedApps.pinned.count)")

        let headItem = apps.pinned[0]
        apps.move(headItem, by: 1)
        check("порядок закреплённых меняется", apps.pinned.count > 1 && apps.pinned[1].id == headItem.id,
              "позиция=\(apps.pinned.firstIndex { $0.id == headItem.id } ?? -1)")

        apps.remove(headItem)
        check("элемент убирается", !apps.pinned.contains { $0.id == headItem.id }, "count=\(apps.pinned.count)")

        // 14 — переводчик (без сети: проверяем логику, а не сервис).
        let translationSuite = "com.dynamicbar.translationsuite"
        UserDefaults.standard.removePersistentDomain(forName: translationSuite)
        let translationDefaults = UserDefaults(suiteName: translationSuite)!
        let translation = TranslationService(defaults: translationDefaults)

        check("по умолчанию выбран источник без ключа",
              translation.provider == .google, "provider=\(translation.provider.rawValue)")
        check("по умолчанию направление EN → RU",
              translation.source == .english && translation.target == .russian)

        translation.input = "привет, как дела"
        translation.translate()
        pump(0.2)
        check("кириллица переключает направление на RU → EN",
              translation.source == .russian && translation.target == .english,
              "\(translation.source.shortTitle) → \(translation.target.shortTitle)")

        translation.input = "hello there"
        translation.translate()
        pump(0.2)
        check("латиница переключает направление на EN → RU",
              translation.source == .english && translation.target == .russian,
              "\(translation.source.shortTitle) → \(translation.target.shortTitle)")

        translation.provider = .yandex
        translation.input = "hello"
        translation.translate()
        pump(0.4)
        check("Яндекс без ключа сообщает об этом",
              translation.errorMessage == TranslationError.missingKey.message,
              "error=\(translation.errorMessage ?? "nil")")

        translation.clear()
        check("очистка сбрасывает ввод, перевод и ошибку",
              translation.input.isEmpty && translation.output.isEmpty && translation.errorMessage == nil)

        translation.provider = .builtIn
        pump(0.8)
        let restoredTranslation = TranslationService(defaults: translationDefaults)
        check("выбранный источник переживает перезапуск",
              restoredTranslation.provider == .builtIn,
              "provider=\(restoredTranslation.provider.rawValue)")

        check("у каждого источника есть понятное название",
              TranslationProvider.allCases.allSatisfy { !$0.title.isEmpty && !$0.shortTitle.isEmpty })
        check("про ключ знает только Яндекс",
              TranslationProvider.allCases.filter(\.needsKey) == [.yandex])
        UserDefaults.standard.removePersistentDomain(forName: translationSuite)

        // 15 — empty snippets are rejected.
        let countBeforeEmptyAdd = snippets.snippets.count
        snippets.add(title: "nope", body: "   \n  ")
        check("empty snippet rejected", snippets.snippets.count == countBeforeEmptyAdd, "count=\(snippets.snippets.count)")

        clipboard.stop()

        // Restore the user's pasteboard.
        pasteboard.clearContents()
        if let savedString { pasteboard.setString(savedString, forType: .string) }

        print("")
        if failures == 0 {
            print("STORETEST OK")
        } else {
            print("STORETEST FAILED (\(failures) check(s))")
            exit(1)
        }
    }

    // MARK: - Helpers

    private static func writePasteboard(_ values: [NSPasteboard.PasteboardType: String], extraTypes: [String] = []) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var types: [NSPasteboard.PasteboardType] = Array(values.keys)
        types.append(contentsOf: extraTypes.map { NSPasteboard.PasteboardType($0) })
        pasteboard.declareTypes(types, owner: nil)
        for (type, value) in values {
            pasteboard.setString(value, forType: type)
        }
        for extra in extraTypes {
            pasteboard.setString("1", forType: NSPasteboard.PasteboardType(extra))
        }
    }

    private static func makeTestImage(width: Int, height: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.white.setFill()
        NSRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2).fill()
        image.unlockFocus()
        return image
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            print("  [ok]   \(name)")
        } else {
            failures += 1
            print("  [FAIL] \(name) \(detail.isEmpty ? "" : "— \(detail)")")
        }
    }
}
