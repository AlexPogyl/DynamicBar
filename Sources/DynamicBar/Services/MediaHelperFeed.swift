import AppKit

/// Runs the MediaRemote helper inside `/usr/bin/perl` and turns its stdout into
/// snapshots. See `Sources/DynamicBarMediaHelper/helper.m` for why perl is the
/// host: since macOS 15.4 `mediaremoted` only answers clients it trusts, and a
/// platform binary is the one route that needs neither an Apple entitlement nor
/// any user permission.
final class MediaHelperFeed {
    struct Snapshot {
        var isPlaying = false
        var title = ""
        var artist = ""
        var album = ""
        var duration: TimeInterval = 0
        var elapsed: TimeInterval = 0
        var rate: Double = 0
        /// When `elapsed` was read. MediaRemote reports a reading, not a running
        /// clock — without this the value cannot be aged.
        var takenAt: Date?
        /// Only present on the update where the artwork changed.
        var artwork: Data?
        /// Name of the app owning the session, resolved from its pid.
        var sourceName: String?
        var sourceIcon: NSImage?
        /// Command codes the player offers right now, or nil when the helper
        /// could not ask. Nil means unknown, not none.
        var commands: Set<Int>?

        func offers(_ command: MediaCommand) -> Bool {
            commands?.contains(Int(command.rawValue)) ?? true
        }

        var isEmpty: Bool { title.isEmpty && artist.isEmpty }
    }

    var onUpdate: ((Snapshot) -> Void)?
    /// Raised when the helper cannot run at all, so the caller can fall back.
    var onUnavailable: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var failures = 0
    private var stopped = false

    private var helperPath: String? {
        Bundle.main.path(forResource: "libdynamicbarmedia", ofType: "dylib")
    }

    var isAvailable: Bool { process?.isRunning == true }

    // MARK: - Lifecycle

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        input = nil
        process?.terminate()
        process = nil
    }

    private func launch() {
        guard !stopped else { return }
        guard let helperPath, FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else {
            Log.error("media helper: /usr/bin/perl or the helper dylib is missing")
            onUnavailable?()
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [
            "-e",
            "use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0x01); while (1) { sleep 3600; }",
            helperPath,
        ]

        let output = Pipe()
        let commands = Pipe()
        task.standardOutput = output
        task.standardInput = commands
        task.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(chunk) }
        }

        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleTermination() }
        }

        do {
            try task.run()
        } catch {
            Log.error("media helper failed to launch: \(error.localizedDescription)")
            onUnavailable?()
            return
        }

        process = task
        input = commands.fileHandleForWriting
        Log.info("media helper started (pid \(task.processIdentifier))")
    }

    private func handleTermination() {
        guard !stopped else { return }
        process = nil
        input = nil
        failures += 1
        // Three straight crashes means the route is gone — perl removed, or the
        // daemon closed to platform binaries too. Let the caller fall back.
        guard failures < 3 else {
            Log.error("media helper died \(failures) times — falling back")
            onUnavailable?()
            return
        }
        Log.info("media helper exited — restarting (attempt \(failures + 1))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.launch() }
    }

    // MARK: - Commands

    func refresh() { write("get") }
    func send(_ command: MediaCommand) { write("cmd \(command.rawValue)") }
    func seek(to seconds: TimeInterval) { write("seek \(Int(seconds))") }

    private func write(_ line: String) {
        guard let input, let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try input.write(contentsOf: data)
        } catch {
            // The helper can die between our check and the write.
            Log.debug("media helper write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Parsing

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            guard !line.isEmpty else { continue }
            handle(line: Data(line))
        }
        // Guard against a runaway line if the helper ever misbehaves.
        if buffer.count > 4_000_000 { buffer.removeAll() }
    }

    /// Now Playing metadata is neither ours nor the user's: a browser tab fills
    /// it through the MediaSession API, so whoever wrote the page decides what
    /// arrives here. Text is capped and stripped of the characters that reorder
    /// a line rather than appear in it — the bidi overrides that make a title
    /// read as something else entirely. Artwork is capped before it reaches the
    /// system image decoder.
    private static let maxTextLength = 512
    private static let maxArtworkBytes = 4 * 1024 * 1024
    private static let bidiControls = CharacterSet(
        charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
    )

    private static func text(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        let scalars = string.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !bidiControls.contains($0)
        }
        return String(String.UnicodeScalarView(scalars.prefix(maxTextLength)))
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }

        if object["error"] != nil {
            // The helper said it cannot work at all. Left alone, its perl host
            // would idle for the rest of the app's life, holding memory for a
            // route that is closed — so the process goes down with the route.
            Log.error("media helper reported: \(object["error"] ?? "unknown")")
            stop()
            onUnavailable?()
            return
        }
        if object["ready"] != nil {
            failures = 0
            return
        }
        failures = 0

        var snapshot = Snapshot()
        snapshot.isPlaying = object["playing"] as? Bool ?? false
        snapshot.title = Self.text(object["title"])
        snapshot.artist = Self.text(object["artist"])
        snapshot.album = Self.text(object["album"])
        snapshot.duration = object["duration"] as? Double ?? 0
        snapshot.elapsed = object["elapsed"] as? Double ?? 0
        snapshot.rate = object["rate"] as? Double ?? 0
        if let seconds = object["timestamp"] as? Double, seconds > 0 {
            snapshot.takenAt = Date(timeIntervalSince1970: seconds)
        }
        if let base64 = object["artwork"] as? String,
           base64.count <= Self.maxArtworkBytes / 3 * 4 + 4,
           let artwork = Data(base64Encoded: base64), artwork.count <= Self.maxArtworkBytes {
            snapshot.artwork = artwork
        }
        if let pid = object["pid"] as? Int, pid > 0 {
            let app = NSRunningApplication(processIdentifier: pid_t(pid))
            snapshot.sourceName = app?.localizedName
            snapshot.sourceIcon = app?.icon
        }
        if let codes = object["commands"] as? [Int] {
            snapshot.commands = Set(codes)
        }
        onUpdate?(snapshot)
    }
}
