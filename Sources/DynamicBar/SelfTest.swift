import AppKit

/// `DynamicBar --selftest`
///
/// Prints a machine-checkable report about the runtime environment and the
/// components the app depends on. Used by `scripts/verify.sh`, and handy when
/// something misbehaves on a fresh machine.
enum SelfTest {
    static func run() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        print("DynamicBar self-test")
        print("  macOS:            \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        print("  architecture:     \(architecture())")
        print("  bundle id:        \(Bundle.main.bundleIdentifier ?? "<none — running outside .app>")")
        print("  bundle path:      \(Bundle.main.bundlePath)")
        print("  executable:       \(Bundle.main.executablePath ?? "?")")
        print("  LSUIElement:      \((Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool) == true)")

        print("")
        print("Screens:")
        for (index, screen) in NSScreen.screens.enumerated() {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            print("  [\(index)] frame=\(rect(screen.frame)) visible=\(rect(screen.visibleFrame)) menuBarHeight=\(Int(menuBar)) scale=\(screen.backingScaleFactor)")
        }
        if let main = NSScreen.main {
            let hotspot = PanelController.hotspotRect(for: main, width: 180, height: 24)
            let geometry = PanelController.geometry(for: main)
            print("  hotspot(x=\(Int(hotspot.minX))..\(Int(hotspot.maxX)), y=\(Int(hotspot.minY))..\(Int(hotspot.maxY)))")
            // Machine readable, consumed by scripts/verify.sh.
            print("  hotspot centre: \(Int(hotspot.midX)),\(Int(hotspot.midY))")
            print("  panel visible frame: \(rect(geometry.visible))")
            print("  panel hidden  frame: \(rect(geometry.hidden))")
        }

        print("")
        print("MediaRemote:")
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        if let handle = dlopen(path, RTLD_NOW) {
            for symbol in ["MRMediaRemoteGetNowPlayingInfo", "MRMediaRemoteSendCommand", "MRMediaRemoteRegisterForNowPlayingNotifications", "MRMediaRemoteGetNowPlayingApplicationPID"] {
                print("  \(symbol): \(dlsym(handle, symbol) != nil ? "ok" : "MISSING")")
            }
        } else {
            print("  dlopen failed: \(String(cString: dlerror()))")
        }

        print("")
        print("Pasteboard:")
        let pasteboard = NSPasteboard.general
        print("  changeCount:      \(pasteboard.changeCount)")
        print("  types:            \((pasteboard.types ?? []).map { $0.rawValue }.joined(separator: ", "))")

        print("")
        print("Stores:")
        let clipboardURL = AppPaths.file("clipboard.json")
        let snippetsURL = AppPaths.file("snippets.json")
        print("  support dir:      \(AppPaths.supportDirectory.path)")
        print("  clipboard.json:   \(FileManager.default.fileExists(atPath: clipboardURL.path) ? "present" : "absent")")
        print("  snippets.json:    \(FileManager.default.fileExists(atPath: snippetsURL.path) ? "present" : "absent")")

        print("")
        print("Громкость системы:")
        let volume = SystemVolume()
        volume.refresh()
        print("  доступна:         \(volume.available)")
        print("  уровень:          \(Int((volume.level * 100).rounded()))%")
        print("  выключен звук:    \(volume.isMuted)")

        print("")
        print("Launch at login:")
        print("  enabled:          \(LaunchAtLogin.isEnabled)")
        print("  launch agent:     \(LaunchAtLogin.agentURL.path) (\(FileManager.default.fileExists(atPath: LaunchAtLogin.agentURL.path) ? "present" : "absent"))")

        print("")
        print("Log file:           \(Log.path)")
        print("SELFTEST OK")
    }

    private static func rect(_ rect: NSRect) -> String {
        "(\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)))"
    }

    private static func architecture() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine
    }
}
