import AppKit

/// Permission-free metadata fallback.
///
/// On macOS 26 `MRMediaRemoteGetNowPlayingInfo` returns
/// `kMRMediaRemoteFrameworkErrorDomain Code=3 "Operation not permitted"` for any
/// app that does not carry Apple's restricted `com.apple.nowplaying.entitlement`
/// (which cannot be self-signed — see README). Transport commands are *not*
/// gated, so playback control keeps working; only the track metadata is hidden.
///
/// This probe recovers *something* useful from window titles. It is deliberately
/// conservative and privacy-scoped:
///   * only apps on a curated allow-list are ever inspected,
///   * browser titles must carry an explicit media marker (e.g. " - YouTube"),
///   * titles that are just the app's own name are rejected,
///   * nothing is logged or persisted.
enum WindowTitleProbe {
    struct Candidate {
        let appName: String
        let bundleID: String
        let title: String
        let isTrackLike: Bool
        let isFrontmost: Bool
    }

    /// Players whose window title is normally the current track.
    static let playerBundleIDs: Set<String> = [
        "com.spotify.client",
        "com.apple.Music",
        "com.apple.iTunes",
        "org.videolan.vlc",
        "com.colliderli.iina",
        "ru.yandex.desktop.music",
        "com.apple.Podcasts",
        "com.apple.QuickTimePlayerX",
        "com.coppertino.Vox",
        "com.swinsian.Swinsian",
        "com.soundcloud.desktop",
        "tv.plex.desktop",
        "com.plexapp.plex",
    ]

    /// Browsers: a title only counts when it clearly belongs to a media page.
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
    ]

    /// Titles ending with one of these are media pages (browser playback).
    static let mediaSuffixes: [String] = [
        " - youtube", " — youtube", " - youtube music", " | spotify", " - spotify",
        " - soundcloud", " - vimeo", " - twitch", " - deezer", " - bandcamp",
        " - apple music", " - mixcloud", " - radio", " - last.fm", " - tidal",
    ]

    /// Per-app phrases that mean "this is the app window, not a track".
    static let titleMarkers: [String: [String]] = [
        "ru.yandex.desktop.music": ["яндекс музыка", "яндекс mузыка", "собираем музыку", "yandex music"],
        "com.spotify.client": ["spotify"],
        "org.videolan.vlc": ["vlc media player", "vlc"],
        "com.colliderli.iina": ["iina"],
        "com.apple.Podcasts": ["подкасты", "podcasts"],
    ]

    /// Inspect the (privacy-scoped) set of media windows currently on screen.
    static func probe() -> [Candidate] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var seenPIDs = Set<pid_t>()
        var candidates: [Candidate] = []

        for entry in list {
            guard let rawPID = entry[kCGWindowOwnerPID as String] as? Int else { continue }
            let pid = pid_t(rawPID)
            // Only normal application windows, one per process.
            guard (entry[kCGWindowLayer as String] as? Int ?? -1) == 0 else { continue }
            guard !seenPIDs.contains(pid) else { continue }
            guard let rawTitle = entry[kCGWindowName as String] as? String, !rawTitle.isEmpty else { continue }
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier,
                  playerBundleIDs.contains(bundleID) || browserBundleIDs.contains(bundleID) else { continue }

            seenPIDs.insert(pid)
            let appName = app.localizedName ?? bundleID
            let (title, trackLike) = interpret(rawTitle, bundleID: bundleID, appName: appName)
            candidates.append(
                Candidate(
                    appName: appName,
                    bundleID: bundleID,
                    title: title.isEmpty ? rawTitle : title,
                    isTrackLike: trackLike,
                    isFrontmost: pid == frontPID
                )
            )
        }
        return candidates
    }

    /// The best guess at "what is playing", if any app genuinely looks like it.
    static func currentTrack() -> Candidate? {
        probe()
            .filter { $0.isTrackLike }
            .sorted { lhs, rhs in
                if lhs.isFrontmost != rhs.isFrontmost { return lhs.isFrontmost }
                return playerBundleIDs.contains(lhs.bundleID) && !playerBundleIDs.contains(rhs.bundleID)
            }
            .first
    }

    /// A media app that is running with a visible window, even if its title tells
    /// us nothing — used to explain the situation to the user.
    static func detectedPlayer() -> String? {
        probe().first?.appName
    }

    // MARK: - Heuristics

    private static func interpret(_ rawTitle: String, bundleID: String, appName: String) -> (String, Bool) {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBrowser = browserBundleIDs.contains(bundleID)

        var mediaMarked = false
        let lowered = title.lowercased()
        for suffix in mediaSuffixes where lowered.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            mediaMarked = true
            break
        }

        guard !title.isEmpty, title.count <= 120 else { return ("", false) }

        let folded = title.lowercased()
        for marker in titleMarkers[bundleID] ?? [] where folded.contains(marker) {
            return ("", false)
        }
        if folded == appName.lowercased() { return ("", false) }

        if isBrowser {
            // Without a media marker a browser title is just a page title.
            return mediaMarked ? (title, true) : ("", false)
        }
        return (title, true)
    }
}
