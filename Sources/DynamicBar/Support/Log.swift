import Foundation

/// Tiny file+stderr logger. Keeps a rotating-ish log at ~/Library/Logs/DynamicBar/DynamicBar.log
/// so the app can be debugged even when launched from Finder (where there is no terminal).
enum Log {
    static let debugEnabled = ProcessInfo.processInfo.environment["DYNAMICBAR_DEBUG"] == "1"

    private static let logURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Logs/DynamicBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("DynamicBar.log")
    }()

    private static let queue = DispatchQueue(label: "com.dynamicbar.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) { emit("INFO ", message) }
    static func error(_ message: String) { emit("ERROR", message) }

    static func debug(_ message: String) {
        guard debugEnabled else { return }
        emit("DEBUG", message)
    }

    private static func emit(_ level: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    /// Path is exposed for the "Reveal log" menu item.
    static var path: String { logURL.path }
}

/// Shared on-disk locations.
enum AppPaths {
    static let supportDirectory: URL = {
        // Tests/preview runs can redirect storage somewhere harmless.
        if let override = ProcessInfo.processInfo.environment["DYNAMICBAR_DATA_DIR"], !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("DynamicBar", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }()

    static func file(_ name: String) -> URL {
        supportDirectory.appendingPathComponent(name)
    }

    /// Изображения из буфера лежат отдельными файлами: держать их в JSON
    /// значило бы переписывать мегабайты на каждое изменение истории.
    static let imagesDirectory: URL = {
        let dir = supportDirectory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
