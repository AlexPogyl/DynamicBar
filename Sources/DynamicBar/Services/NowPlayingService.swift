import AppKit
import Combine

/// Media remote command codes.
///
/// Read live off a real session's `GetSupportedCommandsForPlayer`, not assumed
/// from the old global enum: SeekToPlaybackPosition is 24 there, not the 11 the
/// old numbering would suggest.
enum MediaCommand: Int32 {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case stop = 3
    case nextTrack = 4
    case previousTrack = 5
    case seekToPlaybackPosition = 24
}

/// Where the currently displayed metadata came from.
enum MetadataSource {
    case none
    /// The MediaRemote helper hosted by `/usr/bin/perl` — the normal case.
    case helper
    /// Direct MediaRemote calls from this process. Gatekept by macOS since
    /// 15.4, so it only ever answers for entitled builds.
    case systemNowPlaying
    /// Recovered from a media app's window title — last resort.
    case windowTitle
}

/// Now Playing for whatever the system is playing, browser tabs included.
///
/// Primary source is `MediaHelperFeed`, which reaches MediaRemote through a
/// helper hosted by `/usr/bin/perl`. If that route ever closes, the service
/// falls back to calling MediaRemote directly (works only where macOS still
/// allows it) and then to reading a media window title.
final class NowPlayingService: ObservableObject {
    // MARK: - Published state

    @Published private(set) var title: String = ""
    @Published private(set) var artist: String = ""
    @Published private(set) var album: String = ""
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var sourceAppName: String = ""
    @Published private(set) var sourceAppIcon: NSImage?
    @Published private(set) var duration: Double = 0
    @Published private(set) var hasTrack: Bool = false
    @Published private(set) var metadataSource: MetadataSource = .none
    /// True when macOS refuses to hand over track metadata to this process.
    @Published private(set) var metadataBlockedBySystem = false
    /// A media app running with a visible window, even when its title says
    /// nothing — used to explain the situation.
    @Published private(set) var detectedPlayerApp: String = ""
    /// Whether the player accepts skipping at all. A browser tab playing one
    /// video registers no handler, so the buttons dim rather than lie.
    @Published private(set) var canSkip = true
    @Published private(set) var canSeek = false

    /// True when the perl-hosted helper is driving the metadata.
    @Published private(set) var helperActive = false
    /// False when the private framework could not be loaded at all.
    private(set) var frameworkAvailable = false

    // MARK: - Position anchoring

    /// MediaRemote reports a reading, not a running clock, so the reading is
    /// stored with the moment it was taken and aged from there.
    private var anchorPosition: Double = 0
    private var anchorDate: Date?
    private var anchorRate: Double = 0
    private var artworkKey: String = ""

    func position(at date: Date) -> Double {
        guard let anchorDate else { return anchorPosition }
        let advanced = anchorPosition + date.timeIntervalSince(anchorDate) * anchorRate
        guard duration > 0 else { return max(0, advanced) }
        return min(max(0, advanced), duration)
    }

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(position(at: date) / duration, 0), 1)
    }

    func timeLabel(at date: Date) -> String {
        func format(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            guard total >= 3600 else { return String(format: "%d:%02d", total / 60, total % 60) }
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return "\(format(position(at: date))) / \(format(duration))"
    }

    // MARK: - Sources

    private let feed = MediaHelperFeed()
    private var helperAvailable = true

    // Raw per-source values; the published ones are derived in `recompute()`.
    private var remoteTitle = ""
    private var remoteArtist = ""
    private var remoteAlbum = ""
    private var windowTitleTrack: String?
    private var windowTitleApp: String = ""

    // MARK: - Direct MediaRemote (fallback)

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    private typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (Int32, NSDictionary?) -> UInt8
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void

    private var getInfo: GetInfoFn?
    private var getPID: GetPIDFn?
    private var sendCommand: SendCommandFn?
    private var registerNotifications: RegisterFn?

    private let queue = DispatchQueue(label: "com.dynamicbar.nowplaying", qos: .userInitiated)
    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    private let notificationName = Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")
    private let appChangedNotificationName = Notification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification")

    init() {
        loadFramework()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func loadFramework() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else {
            Log.error("MediaRemote dlopen failed: \(String(cString: dlerror()))")
            return
        }
        getInfo = Self.load(handle, "MRMediaRemoteGetNowPlayingInfo")
        getPID = Self.load(handle, "MRMediaRemoteGetNowPlayingApplicationPID")
        sendCommand = Self.load(handle, "MRMediaRemoteSendCommand")
        registerNotifications = Self.load(handle, "MRMediaRemoteRegisterForNowPlayingNotifications")
        frameworkAvailable = sendCommand != nil
        Log.info("MediaRemote loaded — getInfo=\(getInfo != nil) sendCommand=\(sendCommand != nil)")
    }

    private static func load<T>(_ handle: UnsafeMutableRawPointer, _ name: String) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    // MARK: - Lifecycle

    func start() {
        feed.onUpdate = { [weak self] snapshot in self?.apply(snapshot) }
        feed.onUnavailable = { [weak self] in self?.switchToDirectFallback() }
        feed.start()
        helperActive = true
        startDirectFallbackIfNeeded()
        Log.info("NowPlayingService started (helper first, direct MediaRemote as fallback)")
    }

    func stop() {
        feed.stop()
        refreshTimer?.invalidate()
        refreshTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    /// The panel opened or closed. The helper polls at 1 Hz on its own; this
    /// just asks for a fresh answer immediately.
    func setActive(_ active: Bool) {
        guard active else { return }
        if helperAvailable {
            feed.refresh()
        } else {
            refreshDirect()
        }
    }

    private func switchToDirectFallback() {
        guard helperAvailable else { return }
        helperAvailable = false
        helperActive = false
        Log.info("media helper unavailable — using the direct MediaRemote fallback")
        startDirectFallbackIfNeeded()
        refreshDirect()
    }

    private func startDirectFallbackIfNeeded() {
        guard registerNotifications != nil || getInfo != nil else { return }
        registerNotifications?(DispatchQueue.main)

        for name in [notificationName, appChangedNotificationName] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshDirect()
            }
            observers.append(observer)
        }

        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshDirect()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refreshDirect()
    }

    // MARK: - Snapshot handling

    private func apply(_ snapshot: MediaHelperFeed.Snapshot) {
        guard !snapshot.isEmpty else {
            clearMetadata()
            return
        }

        // Обложка приходит отдельным сообщением и может опоздать: первый
        // снапшот трека часто приходит без неё. Раньше она применялась только
        // вместе со сменой ключа, из-за чего опаздывающая обложка не
        // показывалась вовсе. Теперь ключ лишь сбрасывает старую картинку,
        // а пришедшая обложка применяется всегда.
        let key = "\(snapshot.title)|\(snapshot.artist)|\(snapshot.album)"
        if key != artworkKey {
            artworkKey = key
            artwork = nil
        }
        if let data = snapshot.artwork, let image = NSImage(data: data) {
            artwork = image
        }

        title = snapshot.title
        artist = snapshot.artist
        album = snapshot.album
        duration = snapshot.duration
        isPlaying = snapshot.isPlaying || snapshot.rate > 0
        hasTrack = true
        metadataSource = .helper
        metadataBlockedBySystem = false
        canSkip = snapshot.offers(.nextTrack) && snapshot.offers(.previousTrack)
        canSeek = snapshot.offers(.seekToPlaybackPosition) && snapshot.duration > 0
        if let name = snapshot.sourceName, !name.isEmpty { sourceAppName = name }
        if let icon = snapshot.sourceIcon { sourceAppIcon = icon }

        anchorPosition = snapshot.elapsed
        anchorDate = snapshot.takenAt ?? Date()
        anchorRate = isPlaying ? (snapshot.rate > 0 ? snapshot.rate : 1) : 0
    }

    private func clearMetadata() {
        if hasTrack { hasTrack = false }
        if !title.isEmpty { title = "" }
        if !artist.isEmpty { artist = "" }
        if !album.isEmpty { album = "" }
        if artwork != nil { artwork = nil }
        if !sourceAppName.isEmpty { sourceAppName = "" }
        if sourceAppIcon != nil { sourceAppIcon = nil }
        if duration != 0 { duration = 0 }
        if isPlaying { isPlaying = false }
        artworkKey = ""
        anchorPosition = 0
        anchorDate = nil
        anchorRate = 0
        canSeek = false
        if metadataSource != .none { metadataSource = .none }
        metadataBlockedBySystem = false
        detectedPlayerApp = ""

        // Only the fallback path needs the window-title guess: the helper sees
        // the real record, so when it says nothing plays, nothing plays.
        if !helperAvailable { refreshWindowTitleFallback() }
    }

    // MARK: - Direct fallback reading

    private func refreshDirect() {
        guard !helperAvailable else { return }
        refreshSystemNowPlaying()
        refreshWindowTitleFallback()
    }

    private func refreshSystemNowPlaying() {
        guard let getInfo else { return }
        getInfo(queue) { [weak self] info in
            guard let self else { return }
            let dict = (info as? [String: Any]) ?? [:]
            DispatchQueue.main.async { self.applyDirect(dict) }
        }
        getPID?(queue) { [weak self] pid in
            guard let self, pid > 0 else { return }
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            let name = app.localizedName ?? ""
            let icon = app.icon
            DispatchQueue.main.async {
                if self.sourceAppName != name { self.sourceAppName = name }
                if self.sourceAppIcon !== icon { self.sourceAppIcon = icon }
            }
        }
    }

    private func applyDirect(_ dict: [String: Any]) {
        func string(_ key: String) -> String {
            (dict[key] as? String) ?? ""
        }
        func double(_ key: String) -> Double {
            if let value = dict[key] as? Double { return value }
            if let value = dict[key] as? NSNumber { return value.doubleValue }
            return 0
        }

        remoteTitle = string("kMRMediaRemoteNowPlayingInfoTitle")
        remoteArtist = string("kMRMediaRemoteNowPlayingInfoArtist")
        remoteAlbum = string("kMRMediaRemoteNowPlayingInfoAlbum")
        let rate = double("kMRMediaRemoteNowPlayingInfoPlaybackRate")
        let newDuration = double("kMRMediaRemoteNowPlayingInfoDuration")
        let newElapsed = double("kMRMediaRemoteNowPlayingInfoElapsedTime")

        if duration != newDuration { duration = newDuration }

        if !dict.isEmpty {
            let playing = rate > 0.01
            if isPlaying != playing { isPlaying = playing }
            anchorPosition = newElapsed
            anchorDate = Date()
            anchorRate = playing ? max(rate, 1) : 0
        }

        if let data = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data, let image = NSImage(data: data) {
            artwork = image
        }

        recompute()
    }

    private func refreshWindowTitleFallback() {
        let detected = WindowTitleProbe.detectedPlayer() ?? ""
        if detectedPlayerApp != detected { detectedPlayerApp = detected }

        guard remoteTitle.isEmpty, remoteArtist.isEmpty else {
            if windowTitleTrack != nil {
                windowTitleTrack = nil
                windowTitleApp = ""
            }
            recompute()
            return
        }

        let candidate = WindowTitleProbe.currentTrack()
        let newTrack = candidate?.title
        let newApp = candidate?.appName ?? ""
        if windowTitleTrack != newTrack || windowTitleApp != newApp {
            windowTitleTrack = newTrack
            windowTitleApp = newApp
            Log.debug("metadata fallback via window title: app=\(newApp) found=\(newTrack != nil)")
        }
        recompute()
    }

    /// Merge the fallback sources into the published state.
    private func recompute() {
        guard !helperAvailable else { return }
        let remoteHasTrack = !remoteTitle.isEmpty || !remoteArtist.isEmpty

        if remoteHasTrack {
            if title != remoteTitle { title = remoteTitle }
            if artist != remoteArtist { artist = remoteArtist }
            if album != remoteAlbum { album = remoteAlbum }
            hasTrack = true
            metadataSource = .systemNowPlaying
            metadataBlockedBySystem = false
            if sourceAppName.isEmpty { sourceAppName = "Системный плеер" }
            return
        }

        if let windowTitleTrack, !windowTitleTrack.isEmpty {
            if title != windowTitleTrack { title = windowTitleTrack }
            if !artist.isEmpty { artist = "" }
            if !album.isEmpty { album = "" }
            hasTrack = true
            metadataSource = .windowTitle
            metadataBlockedBySystem = true
            if sourceAppName != windowTitleApp { sourceAppName = windowTitleApp }
            return
        }

        hasTrack = false
        metadataSource = .none
        metadataBlockedBySystem = false
        if !title.isEmpty { title = "" }
        if !artist.isEmpty { artist = "" }
        if !album.isEmpty { album = "" }
        artwork = nil
        if !sourceAppName.isEmpty { sourceAppName = "" }
        canSeek = false
    }

    // MARK: - Control

    /// Whether the most recent command dispatch was accepted.
    private(set) var lastCommandAccepted: Bool?

    @discardableResult
    func send(_ command: MediaCommand) -> Bool {
        var accepted = true
        if helperAvailable {
            feed.send(command)
        } else if let sendCommand {
            accepted = sendCommand(command.rawValue, nil) != 0
        } else {
            accepted = false
        }
        lastCommandAccepted = accepted

        // Optimistic updates; the next snapshot or poll corrects them.
        switch command {
        case .togglePlayPause: isPlaying.toggle()
        case .play: isPlaying = true
        case .pause: isPlaying = false
        default: break
        }
        if command == .play || command == .pause || command == .togglePlayPause {
            anchorPosition = position(at: Date())
            anchorDate = Date()
            anchorRate = isPlaying ? 1 : 0
        }
        if helperAvailable {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.feed.refresh() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.refreshDirect() }
        }
        return accepted
    }

    /// There is no toggle among the per-client codes, so play and pause are sent
    /// explicitly, by whichever state we already know we are in.
    @discardableResult
    func togglePlayPause() -> Bool {
        if helperAvailable {
            return send(isPlaying ? .pause : .play)
        }
        return send(.togglePlayPause)
    }

    @discardableResult func next() -> Bool { send(.nextTrack) }
    @discardableResult func previous() -> Bool { send(.previousTrack) }

    func seek(to seconds: TimeInterval) {
        guard canSeek, duration > 0 else { return }
        let clamped = min(max(0, seconds), duration)
        anchorPosition = clamped
        anchorDate = Date()
        if helperAvailable {
            feed.seek(to: clamped)
        } else {
            _ = sendCommand?(MediaCommand.seekToPlaybackPosition.rawValue,
                             ["kMRMediaRemoteOptionPlaybackPosition": clamped] as NSDictionary)
        }
    }

    // MARK: - Preview hooks (render tests)

    func setPreviewValues(title: String, artist: String, album: String, isPlaying: Bool, elapsed: Double, duration: Double, source: String) {
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.duration = duration
        self.hasTrack = !title.isEmpty
        self.sourceAppName = source
        self.metadataSource = .helper
        anchorPosition = elapsed
        anchorDate = Date()
        anchorRate = isPlaying ? 1 : 0
        canSkip = true
        canSeek = true
    }

    /// Подставить обложку для превью и скриншотов.
    func setPreviewArtwork(_ image: NSImage?) {
        artwork = image
    }

    /// Preview hook for the "nothing playing" state.
    func setDetectedPlayerForPreview(_ name: String) {
        helperActive = true
        title = ""
        artist = ""
        album = ""
        hasTrack = false
        metadataSource = .none
        detectedPlayerApp = name
    }

    /// Preview hook for the degraded (no helper) state.
    func markHelperUnavailableForPreview() {
        helperAvailable = false
        helperActive = false
    }
}
