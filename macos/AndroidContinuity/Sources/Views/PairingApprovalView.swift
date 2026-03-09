import SwiftUI

/// Hosts the pairing approval flow. Observes the PairingManager for
/// pending requests and shows the approval dialog when one arrives.
struct PairingApprovalHost: View {
    @ObservedObject var pairingManager: PairingManager

    var body: some View {
        Group {
            if let request = pairingManager.pendingRequest {
                PairingApprovalView(
                    deviceName: request.deviceName,
                    deviceType: request.deviceType,
                    verificationCode: request.verificationCode,
                    onAllowOnce: { pairingManager.approveOnce() },
                    onAllowAlways: { pairingManager.approveAlways() },
                    onDeny: { pairingManager.deny() }
                )
            } else {
                // No pending request — show nothing
                Text("No pending pairing requests.")
                    .foregroundStyle(.secondary)
                    .frame(width: 300, height: 100)
            }
        }
    }
}

// MARK: - Approval Dialog

struct PairingApprovalView: View {
    let deviceName: String
    let deviceType: String
    let verificationCode: String
    let onAllowOnce: () -> Void
    let onAllowAlways: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: deviceType == "android" ? "iphone" : "desktopcomputer")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("New Device Connection")
                .font(.title2)
                .fontWeight(.semibold)

            Text("\"\(deviceName)\" wants to connect.")
                .foregroundStyle(.secondary)

            Text("Verification Code")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Display code in spaced pairs for readability
            Text(formattedCode)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .padding(.horizontal)
                .accessibilityLabel("Verification code: \(spokenCode)")

            Text("Verify this code matches the code shown on the other device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Deny", role: .destructive) {
                    onDeny()
                }

                Button("Allow Once") {
                    onAllowOnce()
                }

                Button("Allow Always") {
                    onAllowAlways()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    /// Format "123456" as "123 456" for readability.
    private var formattedCode: String {
        guard verificationCode.count == 6 else { return verificationCode }
        let idx = verificationCode.index(verificationCode.startIndex, offsetBy: 3)
        return "\(verificationCode[..<idx]) \(verificationCode[idx...])"
    }

    /// For VoiceOver: read each digit individually.
    private var spokenCode: String {
        verificationCode.map(String.init).joined(separator: " ")
    }
}
