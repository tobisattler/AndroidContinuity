import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import OSLog

/// Manages the gRPC server lifecycle.
///
/// Hosts the PairingService and TransferService on a plaintext HTTP/2 transport.
/// TLS upgrade is planned for a future phase.
@MainActor
final class GrpcServer: ObservableObject {

    // MARK: - Public types

    enum State: Equatable, Sendable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
    }

    // MARK: - Published

    @Published private(set) var state: State = .stopped

    // MARK: - Private

    private static let logger = Logger(subsystem: "com.androidcontinuity", category: "gRPC")
    private var serverTask: Task<Void, Never>?
    private let requestedPort: Int
    private let pairingProvider: PairingServiceProvider
    private let transferProvider: TransferServiceProvider

    // MARK: - Init

    init(
        port: Int = 50051,
        pairingProvider: PairingServiceProvider,
        transferProvider: TransferServiceProvider = TransferServiceProvider()
    ) {
        self.requestedPort = port
        self.pairingProvider = pairingProvider
        self.transferProvider = transferProvider
    }

    // MARK: - Public API

    /// The actual port the server is listening on, or nil if not running.
    var actualPort: Int? {
        if case .running(let port) = state { return port }
        return nil
    }

    /// Start the gRPC server.
    func start() {
        guard serverTask == nil else { return }

        state = .starting
        Self.logger.info("Starting gRPC server on port \(self.requestedPort)...")

        serverTask = Task { [requestedPort, pairingProvider, transferProvider] in
            do {
                let transport = HTTP2ServerTransport.Posix(
                    address: .ipv4(host: "0.0.0.0", port: requestedPort),
                    transportSecurity: .plaintext
                )

                let server = GRPCServer(
                    transport: transport,
                    services: [pairingProvider, transferProvider]
                )

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await server.serve()
                    }

                    // Wait briefly for the server to bind
                    try await Task.sleep(for: .milliseconds(200))

                    let listeningPort = requestedPort
                    await MainActor.run {
                        self.state = .running(port: listeningPort)
                        Self.logger.info("gRPC server running on port \(listeningPort)")
                    }

                    try await group.next()
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.state = .failed(error.localizedDescription)
                        Self.logger.error("gRPC server failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Stop the gRPC server.
    func stop() {
        serverTask?.cancel()
        serverTask = nil
        state = .stopped
        Self.logger.info("gRPC server stopped.")
    }
}
