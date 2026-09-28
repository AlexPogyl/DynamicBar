import Foundation
import ServiceManagement

/// Launch-at-login support.
///
/// Preferred path is `SMAppService.mainApp` (macOS 13+, shows up in
/// System Settings ▸ General ▸ Login Items). Because an ad-hoc signed app can be
/// refused by the service manager, we transparently fall back to a classic
/// per-user LaunchAgent, which always works without any permission prompt.
enum LaunchAtLogin {
    static let agentLabel = "com.dynamicbar.DynamicBar.launchagent"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(agentLabel).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled { return true }
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            if registerWithSMAppService() {
                removeAgent()
                Log.info("launch-at-login: enabled via SMAppService")
                return true
            }
            let ok = installAgent()
            Log.info("launch-at-login: enabled via LaunchAgent (\(ok))")
            return ok
        } else {
            unregisterFromSMAppService()
            removeAgent()
            Log.info("launch-at-login: disabled")
            return true
        }
    }

    // MARK: - SMAppService

    private static func registerWithSMAppService() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if SMAppService.mainApp.status == .enabled { return true }
            try SMAppService.mainApp.register()
            return SMAppService.mainApp.status == .enabled
        } catch {
            Log.info("launch-at-login: SMAppService.register failed (\(error.localizedDescription)) — falling back")
            return false
        }
    }

    private static func unregisterFromSMAppService() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.info("launch-at-login: SMAppService.unregister failed (\(error.localizedDescription))")
        }
    }

    // MARK: - LaunchAgent fallback

    private static func installAgent() -> Bool {
        guard let executable = Bundle.main.executablePath else { return false }
        let directory = agentURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: [.atomic])
        } catch {
            Log.error("launch-at-login: could not write agent (\(error))")
            return false
        }

        // Best-effort bootstrap so it also takes effect for the current session.
        let uid = getuid()
        _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(agentLabel)"])
        let result = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", agentURL.path])
        // bootstrap fails harmlessly if already loaded
        Log.info("launch-at-login: launchctl bootstrap exit=\(result)")
        return true
    }

    private static func removeAgent() {
        let uid = getuid()
        _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(agentLabel)"])
        try? FileManager.default.removeItem(at: agentURL)
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
