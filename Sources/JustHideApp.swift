import AppKit

@main
@MainActor
struct JustHideApp {
    /// Held for the lifetime of the process: NSApplication keeps its delegate
    /// weakly.
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        // Menu bar only: no Dock tile, no app menu of our own.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
