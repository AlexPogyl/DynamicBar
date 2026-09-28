import AppKit

/// Вывод чужого приложения на передний план.
///
/// Тонкость, из-за которой клик «не работал»: `NSRunningApplication.activate`
/// поднимает приложение, но **не разворачивает свёрнутые окна**. Если окно
/// приложения свёрнуто в Dock, визуально не происходит ничего — приложение
/// считается активным, а окна на экране нет.
///
/// Поэтому основной путь — `NSWorkspace.openApplication(activates: true)`:
/// для уже запущенного приложения это ровно то, что делает клик по его иконке
/// в Dock. Launch Services присылает приложению событие «reopen», и оно само
/// разворачивает окно. `activate` остаётся запасным вариантом.
enum AppActivator {
    /// Поднять приложение и, если окна свёрнуты, развернуть их.
    /// Результат проверяется по фактически переднему приложению и пишется в журнал.
    static func bringToFront(_ application: NSRunningApplication,
                             reason: String,
                             completion: (() -> Void)? = nil) {
        if application.isHidden {
            application.unhide()
        }

        let before = NSWorkspace.shared.frontmostApplication
        let name = application.localizedName ?? application.bundleIdentifier ?? "?"

        guard let url = application.bundleURL else {
            application.activate(options: [.activateAllWindows])
            verify(application, name: name, strategy: "activate (нет bundleURL)", before: before, reason: reason, completion: completion)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Log.error("activation[\(reason)]: openApplication для \(name) не удался (\(error.localizedDescription)) — пробую activate")
                    application.activate(options: [.activateAllWindows])
                }
                verify(application,
                       name: name,
                       strategy: error == nil ? "openApplication" : "activate (запасной)",
                       before: before,
                       reason: reason,
                       completion: completion)
            }
        }
    }

    /// Запуск закрытого приложения.
    static func launch(bundleID: String, path: String?, reason: String, completion: ((Bool) -> Void)? = nil) {
        let url: URL?
        if let path {
            url = URL(fileURLWithPath: path)
        } else {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
        guard let url else {
            Log.error("activation[\(reason)]: не нашёл приложение \(bundleID)")
            completion?(false)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Log.error("activation[\(reason)]: запуск \(bundleID) не удался: \(error.localizedDescription)")
                } else {
                    Log.info("activation[\(reason)]: запустил \(bundleID)")
                }
                completion?(error == nil)
            }
        }
    }

    /// Проверка результата: без неё «ничего не произошло» невозможно отличить
    /// от «сработало, но окно свёрнуто».
    private static func verify(_ application: NSRunningApplication,
                               name: String,
                               strategy: String,
                               before: NSRunningApplication?,
                               reason: String,
                               completion: (() -> Void)?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let front = NSWorkspace.shared.frontmostApplication
            let ok = front?.processIdentifier == application.processIdentifier
            let beforeName = before?.localizedName ?? "?"
            let afterName = front?.localizedName ?? "?"
            if ok {
                Log.info("activation[\(reason)]: \(strategy), \(beforeName) → \(afterName) — ок")
            } else {
                Log.error("activation[\(reason)]: \(strategy), \(beforeName) → \(afterName) — приложение вперёд не вышло")
            }
            completion?()
        }
    }
}
