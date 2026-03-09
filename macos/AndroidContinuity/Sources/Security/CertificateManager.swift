import Foundation
import Security
import OSLog

/// Manages a self-signed ECDSA P-256 key pair stored in the Keychain.
///
/// Used by the pairing flow to exchange public keys with Android clients
/// and to sign/verify challenge nonces.
@MainActor
final class CertificateManager: ObservableObject {

    static let shared = CertificateManager()

    private static let logger = Logger(subsystem: "com.androidcontinuity", category: "Certificate")

    /// Keychain tag for the server's private key.
    private let privateKeyTag = "com.androidcontinuity.server.key"
    /// Keychain label for the certificate entry.
    private let certificateLabel = "AndroidContinuity Server"

    // MARK: - Published state

    @Published private(set) var hasIdentity: Bool = false

    // MARK: - Cached

    private var cachedPrivateKey: SecKey?
    private var cachedPublicKeyData: Data?

    // MARK: - Init

    init() {
        loadExistingKey()
    }

    // MARK: - Public API

    /// Returns the DER-encoded public key, generating a key pair if needed.
    func serverPublicKeyData() throws -> Data {
        if let cached = cachedPublicKeyData {
            return cached
        }
        try generateKeyPair()
        guard let data = cachedPublicKeyData else {
            throw CertificateError.generationFailed("Public key data unavailable after generation")
        }
        return data
    }

    /// Returns the private key reference, generating a key pair if needed.
    func serverPrivateKey() throws -> SecKey {
        if let cached = cachedPrivateKey {
            return cached
        }
        try generateKeyPair()
        guard let key = cachedPrivateKey else {
            throw CertificateError.generationFailed("Private key unavailable after generation")
        }
        return key
    }

    /// Deletes the stored key pair from the Keychain.
    func deleteIdentity() {
        deleteKeychainItems()
        cachedPrivateKey = nil
        cachedPublicKeyData = nil
        hasIdentity = false
        Self.logger.info("Identity deleted from Keychain")
    }

    /// Signs data with the server's private key (SHA256 + ECDSA).
    func sign(data: Data) throws -> Data {
        let key = try serverPrivateKey()
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) as Data? else {
            throw CertificateError.signingFailed(
                error?.takeRetainedValue().localizedDescription ?? "Unknown"
            )
        }
        return signature
    }

    /// Verifies a signature against a DER-encoded ECDSA public key.
    func verify(signature: Data, data: Data, publicKeyData: Data) throws -> Bool {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let pubKey = SecKeyCreateWithData(
            publicKeyData as CFData, attrs as CFDictionary, &error
        ) else {
            throw CertificateError.invalidPublicKey(
                error?.takeRetainedValue().localizedDescription ?? "Unknown"
            )
        }
        return SecKeyVerifySignature(
            pubKey, .ecdsaSignatureMessageX962SHA256,
            data as CFData, signature as CFData, &error
        )
    }

    // MARK: - Key Generation

    private func generateKeyPair() throws {
        Self.logger.info("Generating ECDSA P-256 key pair...")
        deleteKeychainItems()

        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: privateKeyTag.data(using: .utf8)!,
                kSecAttrLabel as String: certificateLabel,
            ] as [String: Any],
        ]

        var error: Unmanaged<CFError>?
        guard let privKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &error) else {
            throw CertificateError.generationFailed(
                error?.takeRetainedValue().localizedDescription ?? "Unknown"
            )
        }
        guard let pubKey = SecKeyCopyPublicKey(privKey) else {
            throw CertificateError.generationFailed("Could not extract public key")
        }
        guard let pubData = SecKeyCopyExternalRepresentation(pubKey, &error) as Data? else {
            throw CertificateError.generationFailed(
                error?.takeRetainedValue().localizedDescription ?? "Unknown"
            )
        }

        cachedPrivateKey = privKey
        cachedPublicKeyData = pubData
        hasIdentity = true
        Self.logger.info("Key pair generated — public key \(pubData.count) bytes")
    }

    // MARK: - Keychain

    private func loadExistingKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: privateKeyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let key = item else {
            Self.logger.info("No existing key in Keychain")
            return
        }
        // swiftlint:disable:next force_cast
        let privKey = key as! SecKey
        cachedPrivateKey = privKey

        if let pubKey = SecKeyCopyPublicKey(privKey),
           let pubData = SecKeyCopyExternalRepresentation(pubKey, nil) as Data? {
            cachedPublicKeyData = pubData
            hasIdentity = true
            Self.logger.info("Loaded existing key from Keychain")
        }
    }

    private func deleteKeychainItems() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: privateKeyTag.data(using: .utf8)!,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Errors

enum CertificateError: LocalizedError {
    case generationFailed(String)
    case signingFailed(String)
    case invalidPublicKey(String)

    var errorDescription: String? {
        switch self {
        case .generationFailed(let m): "Certificate generation failed: \(m)"
        case .signingFailed(let m): "Signing failed: \(m)"
        case .invalidPublicKey(let m): "Invalid public key: \(m)"
        }
    }
}
