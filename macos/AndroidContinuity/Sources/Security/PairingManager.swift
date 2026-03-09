import Foundation
import OSLog

/// Manages the pairing lifecycle between Android clients and this Mac.
///
/// Flow:
/// 1. Android calls `RequestPairing` → checks trust store
///    - Already trusted → returns `ALREADY_TRUSTED` + fresh session token
///    - New device → generates verification code + nonce, shows approval dialog
/// 2. Mac user approves/denies in the pairing dialog
/// 3. Android calls `CompletePairing` with the verification code
/// 4. Server verifies and returns a session token
@MainActor
final class PairingManager: ObservableObject {

    private static let logger = Logger(subsystem: "com.androidcontinuity", category: "Pairing")

    // MARK: - Dependencies

    private let deviceStore: PairedDeviceStore
    private let certificateManager: CertificateManager

    // MARK: - Published state (for UI binding)

    /// The pending pairing request awaiting user approval. Nil = idle.
    @Published private(set) var pendingRequest: PendingPairingRequest?

    // MARK: - Internal state

    /// Active session tokens: device_id → SessionInfo
    private var activeSessions: [String: SessionInfo] = [:]

    /// Pending challenges: device_id → PendingChallenge
    private var pendingChallenges: [String: PendingChallenge] = [:]

    // MARK: - Init

    init(deviceStore: PairedDeviceStore, certificateManager: CertificateManager = .shared) {
        self.deviceStore = deviceStore
        self.certificateManager = certificateManager

        // Restore sessions from always-trusted devices
        for device in deviceStore.devices where device.trustLevel == .always {
            if let token = device.sessionToken {
                activeSessions[device.id] = SessionInfo(
                    token: token, deviceId: device.id,
                    trustLevel: .always, createdAt: device.lastSeenDate
                )
            }
        }
    }

    // MARK: - Trust Checks

    func isDeviceTrusted(deviceId: String) -> Bool {
        guard let device = deviceStore.device(withId: deviceId) else { return false }
        return device.trustLevel == .always
    }

    /// Returns a fresh session token for an already-trusted device.
    func sessionForTrustedDevice(deviceId: String) -> String? {
        guard isDeviceTrusted(deviceId: deviceId) else { return nil }
        let token = generateSessionToken()
        activeSessions[deviceId] = SessionInfo(
            token: token, deviceId: deviceId,
            trustLevel: .always, createdAt: Date()
        )
        deviceStore.updateLastSeen(deviceId: deviceId)
        return token
    }

    // MARK: - Challenge Creation

    /// Creates a pairing challenge for a new/once-trusted device.
    func createChallenge(
        deviceId: String, deviceName: String, deviceType: String
    ) -> (verificationCode: String, nonce: Data) {
        let code = generateVerificationCode()
        let nonce = generateNonce()

        pendingChallenges[deviceId] = PendingChallenge(
            deviceId: deviceId, deviceName: deviceName,
            deviceType: deviceType, verificationCode: code,
            nonce: nonce, createdAt: Date()
        )

        // Show the approval dialog
        pendingRequest = PendingPairingRequest(
            deviceId: deviceId, deviceName: deviceName,
            deviceType: deviceType, verificationCode: code
        )

        Self.logger.info("Challenge for '\(deviceName)' — code \(code)")
        return (code, nonce)
    }

    // MARK: - User Approval Callbacks

    func approveOnce() {
        guard let req = pendingRequest else { return }
        finaliseApproval(deviceId: req.deviceId, trustLevel: .once)
    }

    func approveAlways() {
        guard let req = pendingRequest else { return }
        finaliseApproval(deviceId: req.deviceId, trustLevel: .always)
    }

    func deny() {
        guard let req = pendingRequest else { return }
        Self.logger.info("Denied pairing for '\(req.deviceName)'")
        pendingChallenges.removeValue(forKey: req.deviceId)
        pendingRequest = nil
    }

    // MARK: - Complete Pairing (called by gRPC handler)

    func completePairing(
        deviceId: String, verificationCode: String
    ) -> PairingCompletionResult {
        guard let challenge = pendingChallenges[deviceId] else {
            return .failure("No pending challenge")
        }
        guard challenge.verificationCode == verificationCode else {
            pendingChallenges.removeValue(forKey: deviceId)
            return .failure("Verification code mismatch")
        }
        // Has the user responded yet?
        if pendingRequest?.deviceId == deviceId {
            return .pendingApproval // still waiting
        }
        guard let session = activeSessions[deviceId] else {
            return .failure("Pairing was denied")
        }
        pendingChallenges.removeValue(forKey: deviceId)
        Self.logger.info("Pairing completed for '\(challenge.deviceName)'")
        return .success(sessionToken: session.token, trustLevel: session.trustLevel)
    }

    // MARK: - Session Verification

    func verifySession(deviceId: String, sessionToken: String) -> Bool {
        guard let session = activeSessions[deviceId], session.token == sessionToken else {
            return false
        }
        deviceStore.updateLastSeen(deviceId: deviceId)
        return true
    }

    // MARK: - Revocation

    func revokePairing(deviceId: String) {
        activeSessions.removeValue(forKey: deviceId)
        deviceStore.removeDevice(withId: deviceId)
        Self.logger.info("Revoked pairing for '\(deviceId)'")
    }

    // MARK: - Helpers

    private func finaliseApproval(deviceId: String, trustLevel: PairedDevice.TrustLevel) {
        guard let req = pendingRequest, req.deviceId == deviceId else { return }
        let token = generateSessionToken()

        let device = PairedDevice(
            id: deviceId, name: req.deviceName,
            deviceType: req.deviceType, trustLevel: trustLevel,
            firstSeenDate: Date(), lastSeenDate: Date(),
            sessionToken: trustLevel == .always ? token : nil
        )
        deviceStore.addDevice(device)

        activeSessions[deviceId] = SessionInfo(
            token: token, deviceId: deviceId,
            trustLevel: trustLevel, createdAt: Date()
        )
        Self.logger.info("Approved '\(req.deviceName)' — \(trustLevel.rawValue)")
        pendingRequest = nil
    }

    func generateVerificationCode() -> String {
        String(Int.random(in: 100_000...999_999))
    }

    func generateSessionToken() -> String {
        UUID().uuidString
    }

    private func generateNonce() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    }
}

// MARK: - Supporting Types

struct PendingPairingRequest: Identifiable {
    let id = UUID()
    let deviceId: String
    let deviceName: String
    let deviceType: String
    let verificationCode: String
}

struct PendingChallenge {
    let deviceId: String
    let deviceName: String
    let deviceType: String
    let verificationCode: String
    let nonce: Data
    let createdAt: Date
}

struct SessionInfo {
    let token: String
    let deviceId: String
    let trustLevel: PairedDevice.TrustLevel
    let createdAt: Date
}

enum PairingCompletionResult {
    case success(sessionToken: String, trustLevel: PairedDevice.TrustLevel)
    case pendingApproval
    case failure(String)
}
