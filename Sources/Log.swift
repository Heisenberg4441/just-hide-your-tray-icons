import Foundation

/// Opt-in tracing for the calibration loop — the one part of this app whose
/// behaviour depends on how macOS feels about laying out the menu bar today.
/// Run the binary with `JUSTHIDE_DEBUG=1` to see it.
enum Log {
    static let isEnabled = ProcessInfo.processInfo.environment["JUSTHIDE_DEBUG"] == "1"

    static func debug(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        FileHandle.standardError.write("[JustHide] \(message())\n".data(using: .utf8)!)
    }
}
