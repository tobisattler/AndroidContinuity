import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.androidcontinuity", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.logger.info("Application launched.")
        // Services are started by AppState, which is owned by the SwiftUI App.
        // The AppDelegate is kept for any AppKit-level hooks we may need later
        // (e.g., handling URL schemes, dock menu, etc.).
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.logger.info("Application terminating.")
    }
}
