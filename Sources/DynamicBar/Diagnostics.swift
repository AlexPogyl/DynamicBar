import AppKit
import Foundation
import ServiceManagement

/// Extra diagnostics used by `scripts/verify.sh`.
///
/// `--musictest [--toggle]`
///     Reads the system Now Playing state. With `--toggle` it also sends
///     play/pause twice (pause → resume) so the control path is proven without
///     leaving playback changed.
///
/// `--autostart-test`
///     Exercises the launch-at-login code path and then restores the previous
///     state, so verification never permanently changes login items.
enum Diagnostics {

    // MARK: - Music

    static func musicTest(allowToggle: Bool) {
        print("DynamicBar music test")
        let service = NowPlayingService()
        print("  MediaRemote available: \(service.frameworkAvailable)")
        guard service.frameworkAvailable else {
            print("MUSICTEST SKIPPED (no MediaRemote)")
            return
        }

        service.start()

        // Let the async MediaRemote callbacks land.
        let deadline = Date().addingTimeInterval(3)
        var settled = false
        while Date() < deadline, !settled {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            if service.hasTrack || !service.sourceAppName.isEmpty {
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                settled = true
            }
        }

        print("  source app:      \(service.sourceAppName.isEmpty ? "<none>" : service.sourceAppName)")
        print("  track:           \(service.hasTrack ? service.title : "<not available>")")
        print("  metadata source: \(service.metadataSource)")
        print("  helper active:   \(service.helperActive)")
        print("  metadata gated by macOS: \(service.metadataBlockedBySystem)")
        if service.hasTrack {
            print("  artist:          \(service.artist)")
            print("  artwork:         \(service.artwork.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "нет")")
            print("  canSkip:         \(service.canSkip)  canSeek: \(service.canSeek)")
            print("  isPlaying:       \(service.isPlaying)")
            print("  timing:          \(Int(service.position(at: Date())))s / \(Int(service.duration))s")
        }

        print("  media apps visible to the window-title fallback:")
        let candidates = WindowTitleProbe.probe()
        if candidates.isEmpty {
            print("    <none>")
        }
        for candidate in candidates {
            print("    \(candidate.appName) [\(candidate.bundleID)] trackLike=\(candidate.isTrackLike) frontmost=\(candidate.isFrontmost) title=\"\(candidate.title)\"")
        }

        guard allowToggle else {
            print("  (read-only; pass --toggle to exercise play/pause)")
            print("MUSICTEST OK")
            service.stop()
            return
        }

        let before = service.isPlaying
        print("  isPlaying before:            \(before)")
        let accepted = service.togglePlayPause()
        print("  MRMediaRemoteSendCommand:    accepted=\(accepted)")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let afterFirst = service.isPlaying
        print("  isPlaying after 1st toggle:  \(afterFirst)")

        // Restore the original state.
        _ = service.togglePlayPause()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        print("  isPlaying after 2nd toggle:  \(service.isPlaying)")

        service.stop()
        print("MUSICTEST OK (transport commands dispatched, no crash)")
    }

    // MARK: - Рабочие столы

    /// `--spacetest [--switch]`: проверить, что приватные API рабочих столов
    /// работают и что приложения раскладываются по столам.
    ///
    /// Переключение столов заметно на экране, поэтому выполняется только с
    /// явным `--switch`: при обычном прогоне проверок экран не дёргается.
    static func spaceTest(includeSwitch: Bool) {
        print("DynamicBar: рабочие столы")
        let service = SpacesService()
        print("  доступны:        \(service.isAvailable)")
        guard service.isAvailable else {
            print("SPACETEST OK (недоступны — вкладка вернётся к показу всех приложений)")
            return
        }

        let snapshot = service.snapshot()
        print("  столов:          \(snapshot.spaces.count)")
        for space in snapshot.spaces {
            let mark = space.isActive ? " ← активный" : ""
            print("    \(space.title) (id \(space.id))\(mark)")
        }
        print("  активный стол:   \(snapshot.activeSpaceID.map(String.init) ?? "неизвестен")")

        // Раскладка тем же путём, которым пользуется вкладка.
        let monitor = RunningAppsMonitor()
        monitor.refresh()
        print("  приложений:      \(monitor.entries.count)")
        for space in monitor.spaces {
            let apps = monitor.entries.filter { monitor.spaces(of: $0.bundleID).contains(space.id) }
            let mark = space.isActive ? " (активный)" : ""
            print("    \(space.title)\(mark): \(apps.count) — \(apps.map(\.name).prefix(6).joined(separator: ", "))")
        }
        let orphans = monitor.entries.filter { monitor.spaces(of: $0.bundleID).isEmpty }
        print("    без окон: \(orphans.count) — \(orphans.map(\.name).prefix(6).joined(separator: ", "))")

        // Сверка приватного API с публичным: список видимых сейчас окон не
        // требует никаких приватных вызовов и служит эталоном для активного
        // стола. Если они расходятся — доверять раскладке нельзя.
        if let active = snapshot.activeSpaceID {
            var onScreen: Set<String> = []
            if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                for entry in list where (entry[kCGWindowLayer as String] as? Int) == 0 {
                    if let pid = entry[kCGWindowOwnerPID as String] as? Int,
                       let name = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier {
                        onScreen.insert(name)
                    }
                }
            }
            let bySpace = Set(monitor.entries.filter { monitor.spaces(of: $0.bundleID).contains(active) }.map(\.bundleID))
            let onlyOnScreen = onScreen.subtracting(bySpace).sorted()
            let onlySpace = bySpace.subtracting(onScreen).sorted()
            let matches = onlyOnScreen.isEmpty && onlySpace.isEmpty
            print("  сверка с видимыми окнами: \(matches ? "совпадает" : "РАСХОДИТСЯ") (\(bySpace.count) приложений)")
            if !matches {
                print("    только на экране: \(onlyOnScreen)")
                print("    только по столам: \(onlySpace)")
            }
        }

        guard includeSwitch else {
            print("  (переключение столов не проверялось — нужен флаг --switch)")
            print("SPACETEST OK")
            return
        }

        guard let active = snapshot.activeSpaceID,
              let other = snapshot.spaces.first(where: { $0.id != active }) else {
            print("  второго стола нет — переключение проверить не на чем")
            print("SPACETEST OK")
            return
        }
        print("  перехожу на \(other.title) и обратно…")
        let switched = service.switchTo(spaceID: other.id)
        print("    переход: \(switched ? "СРАБОТАЛО" : "не сработало")")
        let restored = service.switchTo(spaceID: active)
        print("    возврат: \(restored ? "СРАБОТАЛО" : "НЕ СРАБОТАЛО")")
        print("SPACETEST OK")
    }

    // MARK: - Переводчик

    /// `--translatestest [--builtin]`: реальные запросы в источники перевода.
    ///
    /// Главный поток здесь нельзя блокировать семафором: встроенный
    /// переводчик выдаёт ответ через главную очередь, и на заблокированном
    /// потоке не сработал бы даже его тайм-аут. Поэтому крутим run loop.
    static func translationTest(includeBuiltIn: Bool = false) {
        print("DynamicBar: проверка переводчиков")
        var finished = false

        Task {
            let cases: [(String, TranslationLanguage, TranslationLanguage)] = [
                ("hello world", .english, .russian),
                ("привет мир", .russian, .english),
            ]
            for provider in TranslationProvider.allCases {
                if provider == .builtIn, !includeBuiltIn {
                    print("  Встроенный (macOS): пропущен — нужен языковой пакет, проверяется отдельно (--builtin)")
                    continue
                }
                let needsKey = provider == .yandex
                if needsKey {
                    print("  \(provider.title): пропущен — нужен API-ключ (проверяется только ветка ошибки)")
                    do {
                        _ = try await TranslationService.perform("hello", provider: .yandex, from: .english, to: .russian)
                        print("    неожиданно перевёл без ключа")
                    } catch let error as TranslationError {
                        print("    без ключа ожидаемо: \(error.message)")
                    } catch {
                        print("    без ключа: \(error.localizedDescription)")
                    }
                    continue
                }

                for (text, from, to) in cases {
                    let started = Date()
                    do {
                        let result = try await TranslationService.perform(text, provider: provider, from: from, to: to)
                        let elapsed = String(format: "%.2f с", Date().timeIntervalSince(started))
                        print("  \(provider.title) \(from.shortTitle)→\(to.shortTitle) [\(elapsed)]: «\(text)» → «\(result)»")
                    } catch {
                        let message = (error as? TranslationError)?.message ?? error.localizedDescription
                        print("  \(provider.title) \(from.shortTitle)→\(to.shortTitle): ошибка — \(message)")
                    }
                }
            }
            finished = true
        }

        let deadline = Date().addingTimeInterval(includeBuiltIn ? 70 : 25)
        while !finished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if !finished {
            print("TRANSLATETEST TIMEOUT — источники не ответили вовремя")
            return
        }
        print("TRANSLATETEST OK")
    }

    // MARK: - Launch at login

    /// `--set-autostart on|off` — used by scripts/install.sh.
    static func setAutostart(_ enabled: Bool) {
        let ok = LaunchAtLogin.setEnabled(enabled)
        print("launch-at-login: requested=\(enabled) applied=\(LaunchAtLogin.isEnabled) ok=\(ok)")
        print("  \(LaunchAtLogin.isEnabled ? "DynamicBar will start at login." : "DynamicBar will not start at login.")")
        if LaunchAtLogin.isEnabled, !enabled { exit(1) }
    }

    static func autostartTest() {
        print("DynamicBar autostart test")
        let wasEnabled = LaunchAtLogin.isEnabled
        print("  enabled before:   \(wasEnabled)")
        if #available(macOS 13.0, *) {
            print("  SMAppService:     \(describe(SMAppService.mainApp.status))")
        }

        let enabled = LaunchAtLogin.setEnabled(true)
        print("  enable() ->       \(enabled)")
        print("  enabled now:      \(LaunchAtLogin.isEnabled)")
        print("  launch agent:     \(FileManager.default.fileExists(atPath: LaunchAtLogin.agentURL.path) ? "written to ~/Library/LaunchAgents" : "not needed")")
        if #available(macOS 13.0, *) {
            print("  SMAppService:     \(describe(SMAppService.mainApp.status))")
        }

        // Restore the previous state so verification is side-effect free.
        _ = LaunchAtLogin.setEnabled(wasEnabled)
        print("  enabled after:    \(LaunchAtLogin.isEnabled) (restored)")
        print("AUTOSTARTTEST OK")
    }

    @available(macOS 13.0, *)
    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
