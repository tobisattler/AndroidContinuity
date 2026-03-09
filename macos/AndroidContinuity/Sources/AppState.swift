import Foundation
import OSLog

/// Central application state that owns and coordinates all services.
///
/// Observed by the MenuBarView to display live status.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published services

    @Published var grpcServer: GrpcServer
    @Published var bonjourAdvertiser: BonjourAdvertiser
    @Published var settingsStore: SettingsStore
    @Published var pairedDeviceStore: PairedDeviceStore
    @Published var pairingManager: PairingManager
    @Published var certificateManager: CertificateManager

    /// Names of files received in this session (most recent first).
    @Published var recentFiles: [String] = []

    // MARK: - Computed

    var isRunning: Bool {
        if case .running = grpcServer.state, case .advertising = bonjourAdvertiser.state {
            return true
        }
        return false
    }

    var statusText: String {
        switch (grpcServer.state, bonjourAdvertiser.state) {
        case (.running, .advertising):
            return "Ready — Waiting for connections"
        case (.starting, _), (_, .starting):
            return "Starting..."
        case (.failed(let msg), _):
            return "Server error: \(msg)"
        case (_, .failed(let msg)):
            return "Network error: \(msg)"
        case (.stopped, _), (_, .stopped):
            return "Stopped"
        default:
            return "Unknown"
        }
    }

    // MARK: - Private

    private static let logger = Logger(subsystem: "com.androidcontinuity", category: "AppState")
    private static let defaultPort = 50051

    // MARK: - Init

    init() {
        let settingsStore = SettingsStore()
        let pairedDeviceStore = PairedDeviceStore()
        let certificateManager = CertificateManager.shared
        let pairingManager = PairingManager(
            deviceStore: pairedDeviceStore,
            certificateManager: certificateManager
        )

        self.settingsStore = settingsStore
        self.pairedDeviceStore = pairedDeviceStore
        self.certificateManager = certificateManager
        self.pairingManager = pairingManager

        // Bridge PairingManager (MainActor) to PairingServiceProvider (Sendable/NIO)
        // via a closure that hops to MainActor when the gRPC handler needs data.
        let pairingProvider = PairingServiceProvider(
            pairingManagerQuery: { @Sendable query in
                await MainActor.run { query(pairingManager) }
            }
        )

        // Placeholder — we need self for the onFileReceived closure,
        // so we create a temporary server first and replace it below.
        self.grpcServer = GrpcServer(
            port: Self.defaultPort,
            pairingProvider: pairingProvider
        )
        self.bonjourAdvertiser = BonjourAdvertiser(grpcPort: UInt16(Self.defaultPort))

        // Now that self is available, rebuild with the real TransferServiceProvider
        let transferProvider = TransferServiceProvider(
            downloadFolder: { @Sendable [weak self] in
                await MainActor.run { self?.settingsStore.effectiveDownloadFolder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first! }
            },
            verifySession: { @Sendable [weak self] deviceId, sessionToken in
                await MainActor.run { self?.pairingManager.verifySession(deviceId: deviceId, sessionToken: sessionToken) ?? false }
            },
            onFileReceived: { @Sendable [weak self] fileName in
                await MainActor.run { self?.recentFiles.insert(fileName, at: 0) }
            }
        )

        self.grpcServer = GrpcServer(
            port: Self.defaultPort,
            pairingProvider: pairingProvider,
            transferProvider: transferProvider
        )
    }

    // MARK: - Lifecycle

    func startServices() {
        Self.logger.info("Starting all services...")

        // Ensure we have a key pair for pairing
        do {
            _ = try certificateManager.serverPublicKeyData()
        } catch {
            Self.logger.error("Failed to initialise certificate: \(error.localizedDescription)")
        }

        // Start gRPC server
        grpcServer.start()

        // Start Bonjour advertisement
        if let port = grpcServer.actualPort {
            bonjourAdvertiser.updateGrpcPort(UInt16(port))
        }
        bonjourAdvertiser.startAdvertising()

        Self.logger.info("All services started.")
    }

    func stopServices() {
        Self.logger.info("Stopping all services...")
        bonjourAdvertiser.stopAdvertising()
        grpcServer.stop()
        Self.logger.info("All services stopped.")
    }
}
