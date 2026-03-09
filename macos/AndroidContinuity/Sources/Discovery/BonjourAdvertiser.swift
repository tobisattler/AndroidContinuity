import Foundation
import Network
import OSLog

/// Advertises the AndroidContinuity service via Bonjour/mDNS so that
/// Android devices on the same local network can discover this Mac.
///
/// The advertiser publishes a `_androidcontinuity._tcp.` service with
/// a TXT record containing the gRPC server port and protocol version.
@MainActor
final class BonjourAdvertiser: ObservableObject {

    // MARK: - Public types

    enum State: Equatable, Sendable {
        case stopped
        case starting
        case advertising(port: UInt16)
        case failed(String)
    }

    // MARK: - Published state

    @Published private(set) var state: State = .stopped

    // MARK: - Constants

    static let serviceType = "_androidcontinuity._tcp."
    private static let logger = Logger(subsystem: "com.androidcontinuity", category: "Bonjour")

    // MARK: - Private

    private var listener: NWListener?
    private var grpcPort: UInt16

    // MARK: - Init

    /// - Parameter grpcPort: The port the gRPC server is listening on.
    ///   This port is published in the Bonjour TXT record so Android can connect.
    init(grpcPort: UInt16 = 0) {
        self.grpcPort = grpcPort
    }

    // MARK: - Public API

    /// Update the gRPC port advertised in the TXT record.
    /// Call this after the gRPC server has started and determined its actual port.
    func updateGrpcPort(_ port: UInt16) {
        self.grpcPort = port
        // If already advertising, update the service
        if case .advertising = state {
            listener?.service = makeService()
        }
    }

    /// Start advertising on the local network.
    func startAdvertising() {
        guard listener == nil else { return }

        state = .starting
        Self.logger.info("Starting Bonjour advertisement...")

        do {
            // We use a TCP listener on port 0 (ephemeral) purely for Bonjour registration.
            // The actual gRPC server listens on its own port — the Bonjour TXT record
            // tells clients which port to connect to.
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: .any)

            listener.service = makeService()

            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(newState)
                }
            }

            // We don't actually accept connections on this listener.
            // Connections go directly to the gRPC server port.
            listener.newConnectionHandler = { connection in
                connection.cancel()
            }

            listener.start(queue: .global(qos: .utility))
            self.listener = listener

        } catch {
            Self.logger.error("Failed to create NWListener: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Stop advertising.
    func stopAdvertising() {
        listener?.cancel()
        listener = nil
        state = .stopped
        Self.logger.info("Bonjour advertisement stopped.")
    }

    // MARK: - Private helpers

    private func makeService() -> NWListener.Service {
        // Build TXT record data for discovery metadata
        var txtRecord = NWTXTRecord()
        txtRecord["grpc_port"] = "\(grpcPort)"
        txtRecord["proto_major"] = "1"
        txtRecord["proto_minor"] = "0"
        txtRecord["device_name"] = Host.current().localizedName ?? "Mac"

        return NWListener.Service(
            name: Host.current().localizedName ?? "AndroidContinuity-Mac",
            type: Self.serviceType,
            txtRecord: txtRecord
        )
    }

    private func handleListenerState(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            let actualPort = listener?.port?.rawValue ?? grpcPort
            state = .advertising(port: actualPort)
            Self.logger.info("Bonjour advertising as '\(Host.current().localizedName ?? "Mac")' — gRPC port: \(self.grpcPort)")

        case .failed(let error):
            Self.logger.error("Bonjour listener failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            // Attempt restart after failure
            listener?.cancel()
            listener = nil

        case .cancelled:
            state = .stopped

        case .waiting(let error):
            Self.logger.warning("Bonjour listener waiting: \(error.localizedDescription)")

        default:
            break
        }
    }
}
