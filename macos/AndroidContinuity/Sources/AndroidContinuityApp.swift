import SwiftUI

@main
struct AndroidContinuityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            MenuBarLabel(appState: appState)
        }

        Settings {
            SettingsView(
                settingsStore: appState.settingsStore,
                pairedDeviceStore: appState.pairedDeviceStore
            )
        }

        // Pairing approval dialog — shown as a standalone window
        // when an Android device requests pairing.
        Window("Pairing Request", id: "pairing-approval") {
            PairingApprovalHost(pairingManager: appState.pairingManager)
                .onAppear {
                    // Bring the window to front when it appears
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onChange(of: appState.pairingManager.pendingRequest?.id) { _, newValue in
                    if newValue == nil {
                        // Request was handled — close the window
                        NSApp.keyWindow?.close()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// The menu bar icon changes based on app state.
struct MenuBarLabel: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Image(systemName: appState.isRunning ? "arrow.triangle.swap" : "exclamationmark.triangle")
            .symbolRenderingMode(.hierarchical)
    }
}
