import Foundation
import GRPCCore
import OSLog

/// Server-side implementation of the PairingService gRPC service.
///
/// Routes RPCs through a `PairingManager` (MainActor-isolated) that
/// handles trust lookups, user approval, and session management.
struct PairingServiceProvider: ACPairingService.SimpleServiceProtocol {

    private static let logger = Logger(subsystem: "com.androidcontinuity", category: "PairingRPC")

    /// Sendable closure that hops to MainActor and queries the PairingManager.
    private let askPairingManager: @Sendable (
        @MainActor @Sendable (PairingManager) -> PairingManagerAnswer
    ) async -> PairingManagerAnswer

    init(
        pairingManagerQuery: @escaping @Sendable (
            @MainActor @Sendable (PairingManager) -> PairingManagerAnswer
        ) async -> PairingManagerAnswer
    ) {
        self.askPairingManager = pairingManagerQuery
    }

    // MARK: - RequestPairing

    func requestPairing(
        request: ACPairingRequest,
        context: GRPCCore.ServerContext
    ) async throws -> ACPairingChallenge {
        let deviceName = request.deviceInfo.deviceName
        let deviceId = request.deviceInfo.deviceID
        let deviceType = request.deviceInfo.deviceType == .android ? "android" : "unknown"

        Self.logger.info("Pairing request from '\(deviceName)' (id: \(deviceId))")

        let answer = await askPairingManager { @MainActor pm in
            if pm.isDeviceTrusted(deviceId: deviceId) {
                let token = pm.sessionForTrustedDevice(deviceId: deviceId) ?? ""
                return .alreadyTrusted(sessionToken: token)
            } else {
                let (code, nonce) = pm.createChallenge(
                    deviceId: deviceId,
                    deviceName: deviceName,
                    deviceType: deviceType
                )
                return .newDevice(verificationCode: code, nonce: nonce)
            }
        }

        var challenge = ACPairingChallenge()

        switch answer {
        case .alreadyTrusted(let token):
            Self.logger.info("Device '\(deviceName)' already trusted")
            challenge.challengeType = .alreadyTrusted
            challenge.sessionToken = token

        case .newDevice(let code, let nonce):
            Self.logger.info("New device '\(deviceName)' — code \(code)")
            challenge.challengeType = .newDevice
            challenge.verificationCode = code
            challenge.challengeNonce = nonce

        default:
            break
        }

        // Attach server public key
        if let pubData = try? await MainActor.run(body: { try CertificateManager.shared.serverPublicKeyData() }) {
            challenge.serverCertificate = pubData
        }

        return challenge
    }

    // MARK: - CompletePairing

    func completePairing(
        request: ACPairingChallengeResponse,
        context: GRPCCore.ServerContext
    ) async throws -> ACPairingResult {
        let deviceId = request.deviceID
        Self.logger.info("Complete pairing from '\(deviceId)'")

        // Poll for user decision (up to 60 s)
        let deadline = Date().addingTimeInterval(60)

        while Date() < deadline {
            let answer = await askPairingManager { @MainActor pm in
                let result = pm.completePairing(
                    deviceId: deviceId,
                    verificationCode: request.verificationCode
                )
                switch result {
                case .success(let token, let trust):
                    return .pairingDone(token: token, trustLevel: trust)
                case .pendingApproval:
                    return .pending
                case .failure(let msg):
                    return .pairingFailed(msg)
                }
            }

            switch answer {
            case .pairingDone(let token, let trust):
                var result = ACPairingResult()
                result.status = .ok
                result.sessionToken = token
                result.trustLevel = trust == .always ? .always : .once
                result.message = "Paired successfully"
                return result

            case .pairingFailed(let msg):
                var result = ACPairingResult()
                result.status = .rejected
                result.message = msg
                return result

            case .pending:
                try await Task.sleep(for: .milliseconds(500))
                continue

            default:
                break
            }
            break
        }

        // Timeout
        var result = ACPairingResult()
        result.status = .timeout
        result.message = "Approval timed out"
        Self.logger.warning("Pairing timed out for '\(deviceId)'")
        return result
    }

    // MARK: - VerifySession

    func verifySession(
        request: ACSessionVerification,
        context: GRPCCore.ServerContext
    ) async throws -> ACSessionVerificationResult {
        let deviceId = request.deviceID
        Self.logger.info("Session verify for '\(deviceId)'")

        let answer = await askPairingManager { @MainActor pm in
            let valid = pm.verifySession(deviceId: deviceId, sessionToken: request.sessionToken)
            return valid ? .sessionValid : .sessionInvalid
        }

        var result = ACSessionVerificationResult()
        switch answer {
        case .sessionValid:
            result.valid = true
            result.status = .ok
        default:
            result.valid = false
            result.status = .rejected
        }
        return result
    }

    // MARK: - RevokePairing

    func revokePairing(
        request: ACRevokePairingRequest,
        context: GRPCCore.ServerContext
    ) async throws -> ACRevokePairingResponse {
        let deviceId = request.deviceID
        Self.logger.info("Revoke pairing for '\(deviceId)'")

        let answer = await askPairingManager { @MainActor pm in
            let valid = pm.verifySession(deviceId: deviceId, sessionToken: request.sessionToken)
            if valid { pm.revokePairing(deviceId: deviceId) }
            return valid ? .sessionValid : .sessionInvalid
        }

        var response = ACRevokePairingResponse()
        switch answer {
        case .sessionValid:
            response.status = .ok
        default:
            response.status = .rejected
        }
        return response
    }
}

// MARK: - Answer type (Sendable bridge)

/// Sendable enum to pass data back from the @MainActor PairingManager.
enum PairingManagerAnswer: Sendable {
    case alreadyTrusted(sessionToken: String)
    case newDevice(verificationCode: String, nonce: Data)
    case pairingDone(token: String, trustLevel: PairedDevice.TrustLevel)
    case pairingFailed(String)
    case pending
    case sessionValid
    case sessionInvalid
}
