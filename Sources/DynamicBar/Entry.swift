import AppKit

/// Process entry point.
///
/// Normal run          : `.accessory` app with a menu bar item and the hover panel.
/// `--selftest`        : print environment/diagnostics, exit.
/// `--storetest`       : headless clipboard/snippet logic tests, exit.
/// `--rendertest DIR`  : rasterise the panel UI to PNGs in DIR, exit.
/// `--musictest`       : report the system Now Playing state; `--toggle` also
///                       exercises play/pause and restores the previous state.
/// `--autostart-test`  : exercise launch-at-login registration, then restore.
/// `--showtest`        : start normally, force show/hide the panel, print geometry, exit.
/// `--settingstest`    : open the settings window and confirm it on screen, exit.
/// `--animtest`        : measure animation frame pacing, exit.
@main
enum DynamicBarMain {
    static func main() {
        let args = CommandLine.arguments

        if args.contains("--selftest") {
            SelfTest.run()
            exit(0)
        }

        if args.contains("--storetest") {
            StoreTest.run()
            exit(0)
        }

        if args.contains("--musictest") {
            Diagnostics.musicTest(allowToggle: args.contains("--toggle"))
            exit(0)
        }

        if let index = args.firstIndex(of: "--screenshot") {
            let directory = args.count > index + 1 ? args[index + 1] : NSTemporaryDirectory() + "dynamicbar-shots"
            ScreenshotTest.run(outputDirectory: directory)
            exit(0)
        }

        if args.contains("--translatestest") {
            Diagnostics.translationTest(includeBuiltIn: args.contains("--builtin"))
            exit(0)
        }

        if args.contains("--autostart-test") {
            Diagnostics.autostartTest()
            exit(0)
        }

        if let index = args.firstIndex(of: "--set-autostart"), args.count > index + 1 {
            Diagnostics.setAutostart(args[index + 1] == "on" || args[index + 1] == "true")
            exit(0)
        }

        if let index = args.firstIndex(of: "--rendertest") {
            let directory = args.count > index + 1 ? args[index + 1] : NSTemporaryDirectory() + "dynamicbar-render"
            RenderTest.run(outputDirectory: directory)
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate(showTest: args.contains("--showtest"),
                                   settingsTest: args.contains("--settingstest"),
                                   animationTest: args.contains("--animtest"),
                                   activationTest: args.contains("--activationtest"))
        app.delegate = delegate
        // .accessory == no Dock icon, no app menu, but status items still work.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
