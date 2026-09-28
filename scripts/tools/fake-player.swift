// Fake "now playing" source used ONLY by scripts/verify.sh.
//
// It plays a silent audio loop and publishes Now Playing metadata through the
// public MediaPlayer API. That makes it a real system-wide Now Playing client,
// so DynamicBar's MediaRemote read/control path can be verified end to end
// without touching the user's music library.
//
// Every transport command it receives is appended to the file given as argv[1].

import AppKit
import AVFoundation
import MediaPlayer

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: fake-player <command-log-path>\n".utf8))
    exit(2)
}
let logPath = CommandLine.arguments[1]
try? "".write(toFile: logPath, atomically: true, encoding: .utf8)

func log(_ message: String) {
    let line = "\(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }
}

// ------------------------------------------------------- inaudible test tone --
// A 30 Hz tone at -54 dBFS: real (non-silent) audio as far as CoreAudio and the
// Now Playing daemon are concerned, but inaudible on any laptop speaker.
func writeInaudibleWav(to url: URL, seconds: Double = 4) {
    let sampleRate = 44100
    let channels = 2
    let frames = Int(Double(sampleRate) * seconds)
    let dataBytes = frames * channels * 2
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(Data("RIFF".utf8)); append(UInt32(36 + dataBytes))
    data.append(Data("WAVE".utf8))
    data.append(Data("fmt ".utf8)); append(UInt32(16))
    append(UInt16(1)); append(UInt16(channels)); append(UInt32(sampleRate))
    append(UInt32(sampleRate * channels * 2)); append(UInt16(channels * 2)); append(UInt16(16))
    data.append(Data("data".utf8)); append(UInt32(dataBytes))
    let framesData = frames
    for frame in 0..<framesData {
        let phase = 2.0 * Double.pi * 30.0 * Double(frame) / Double(sampleRate)
        let value = Int16(64.0 * sin(phase))
        for _ in 0..<channels {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
    }
    try? data.write(to: url)
}

let wavURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dynamicbar-silence.wav")
writeInaudibleWav(to: wavURL)

// --------------------------------------------------------------------- audio --
var player: AVAudioPlayer?
do {
    player = try AVAudioPlayer(contentsOf: wavURL)
    player?.numberOfLoops = -1
    player?.volume = 1.0  // buffer is all zeros, so still silent
    player?.play()
    log("audio started: \(player?.isPlaying == true)")
} catch {
    log("audio failed: \(error)")
}

// ---------------------------------------------------------------- now playing --
let center = MPNowPlayingInfoCenter.default()
center.nowPlayingInfo = [
    MPMediaItemPropertyTitle: "DynamicBar Verification Track",
    MPMediaItemPropertyArtist: "Loopback Signal",
    MPMediaItemPropertyAlbumTitle: "Now Playing Pipeline Test",
    MPMediaItemPropertyPlaybackDuration: 214.0,
    MPNowPlayingInfoPropertyElapsedPlaybackTime: 42.0,
    MPNowPlayingInfoPropertyPlaybackRate: 1.0,
]
center.playbackState = .playing
log("published now playing info")

let commands = MPRemoteCommandCenter.shared()
func attach(_ command: MPRemoteCommand, _ name: String) {
    command.isEnabled = true
    command.addTarget { _ in
        log("COMMAND \(name)")
        return .success
    }
}
attach(commands.playCommand, "play")
attach(commands.pauseCommand, "pause")
attach(commands.togglePlayPauseCommand, "togglePlayPause")
attach(commands.nextTrackCommand, "nextTrack")
attach(commands.previousTrackCommand, "previousTrack")
log("command handlers registered")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Re-publish periodically; some players get dropped by the daemon after a while.
Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
    center.nowPlayingInfo = [
        MPMediaItemPropertyTitle: "DynamicBar Verification Track",
        MPMediaItemPropertyArtist: "Loopback Signal",
        MPMediaItemPropertyAlbumTitle: "Now Playing Pipeline Test",
        MPMediaItemPropertyPlaybackDuration: 214.0,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: 42.0,
        MPNowPlayingInfoPropertyPlaybackRate: 1.0,
    ]
    center.playbackState = .playing
    if player?.isPlaying != true { player?.play() }
}
log("fake player ready")
app.run()
