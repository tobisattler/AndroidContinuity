package com.androidcontinuity.data.remote

import android.os.Build
import android.util.Log
import com.androidcontinuity.discovery.DiscoveredDevice
import com.androidcontinuity.proto.DeviceInfo
import com.androidcontinuity.proto.DeviceType
import com.androidcontinuity.proto.PairingChallengeResponse
import com.androidcontinuity.proto.PairingChallengeType
import com.androidcontinuity.proto.PairingRequest
import com.androidcontinuity.proto.PairingServiceGrpcKt.PairingServiceCoroutineStub
import com.androidcontinuity.proto.ProtocolVersion
import com.androidcontinuity.proto.StatusCode
import com.google.protobuf.ByteString
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Repository that manages the pairing flow with a discovered Mac.
 *
 * Exposes a clean Kotlin API over the gRPC PairingService. The flow:
 * 1. [requestPairing] sends device info → receives challenge with verification code
 * 2. User verifies the code matches on both devices
 * 3. [completePairing] sends the code back → receives session token
 *
 * Session tokens are cached for reuse in the transfer flow.
 */
@Singleton
class PairingRepository @Inject constructor(
    private val channelProvider: GrpcChannelProvider,
) {
    companion object {
        private const val TAG = "PairingRepo"
    }

    /** Cached session tokens: device service name → token */
    private val sessionTokens = mutableMapOf<String, String>()

    /** This device's unique ID (persistent across app restarts via random UUID). */
    val deviceId: String = UUID.randomUUID().toString()

    // MARK: - Public API

    /**
     * Step 1: Request pairing with a Mac.
     *
     * @return [PairingChallengeResult] with the verification code to show the user,
     *         or an already-trusted result with a session token.
     */
    suspend fun requestPairing(device: DiscoveredDevice): PairingChallengeResult {
        return try {
            val stub = PairingServiceCoroutineStub(channelProvider.channelFor(device))
            val request = PairingRequest.newBuilder()
                .setDeviceInfo(buildDeviceInfo())
                .build()

            val challenge = stub.requestPairing(request)

            when (challenge.challengeType) {
                PairingChallengeType.PAIRING_CHALLENGE_TYPE_ALREADY_TRUSTED -> {
                    val token = challenge.sessionToken
                    sessionTokens[device.serviceName] = token
                    Log.i(TAG, "Already trusted by ${device.name}")
                    PairingChallengeResult.AlreadyTrusted(sessionToken = token)
                }

                PairingChallengeType.PAIRING_CHALLENGE_TYPE_NEW_DEVICE -> {
                    Log.i(TAG, "New device — verification code: ${challenge.verificationCode}")
                    PairingChallengeResult.NeedsVerification(
                        verificationCode = challenge.verificationCode,
                        challengeNonce = challenge.challengeNonce.toByteArray(),
                        serverPublicKey = challenge.serverCertificate.toByteArray(),
                    )
                }

                PairingChallengeType.PAIRING_CHALLENGE_TYPE_DENIED -> {
                    PairingChallengeResult.Denied
                }

                else -> {
                    PairingChallengeResult.Error("Unknown challenge type")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "requestPairing failed", e)
            PairingChallengeResult.Error(e.message ?: "Unknown error")
        }
    }

    /**
     * Step 2: Complete pairing by echoing back the verification code.
     *
     * @return [PairingCompletionResult] with the session token on success.
     */
    suspend fun completePairing(
        device: DiscoveredDevice,
        verificationCode: String,
    ): PairingCompletionResult {
        return try {
            val stub = PairingServiceCoroutineStub(channelProvider.channelFor(device))
            val request = PairingChallengeResponse.newBuilder()
                .setDeviceId(deviceId)
                .setVerificationCode(verificationCode)
                .setSignedChallenge(ByteString.EMPTY) // TODO: actual signing in Phase 5
                .build()

            val result = stub.completePairing(request)

            when (result.status) {
                StatusCode.STATUS_CODE_OK -> {
                    sessionTokens[device.serviceName] = result.sessionToken
                    Log.i(TAG, "Pairing completed with ${device.name}")
                    PairingCompletionResult.Success(
                        sessionToken = result.sessionToken,
                        trustLevel = result.trustLevel,
                    )
                }

                StatusCode.STATUS_CODE_TIMEOUT -> {
                    PairingCompletionResult.Timeout
                }

                else -> {
                    PairingCompletionResult.Rejected(result.message)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "completePairing failed", e)
            PairingCompletionResult.Error(e.message ?: "Unknown error")
        }
    }

    /**
     * Returns the cached session token for a device, or null if not paired.
     */
    fun sessionToken(forDevice: DiscoveredDevice): String? {
        return sessionTokens[forDevice.serviceName]
    }

    // MARK: - Helpers

    private fun buildDeviceInfo(): DeviceInfo {
        return DeviceInfo.newBuilder()
            .setDeviceId(deviceId)
            .setDeviceName("${Build.MANUFACTURER} ${Build.MODEL}")
            .setDeviceType(DeviceType.DEVICE_TYPE_ANDROID)
            .setAppVersion("1.0.0")
            .setProtocolVersion(
                ProtocolVersion.newBuilder()
                    .setMajor(1)
                    .setMinor(0)
                    .build()
            )
            .build()
    }
}

// MARK: - Result types

sealed interface PairingChallengeResult {
    data class AlreadyTrusted(val sessionToken: String) : PairingChallengeResult
    data class NeedsVerification(
        val verificationCode: String,
        val challengeNonce: ByteArray,
        val serverPublicKey: ByteArray,
    ) : PairingChallengeResult
    data object Denied : PairingChallengeResult
    data class Error(val message: String) : PairingChallengeResult
}

sealed interface PairingCompletionResult {
    data class Success(
        val sessionToken: String,
        val trustLevel: com.androidcontinuity.proto.TrustLevel,
    ) : PairingCompletionResult
    data object Timeout : PairingCompletionResult
    data class Rejected(val message: String) : PairingCompletionResult
    data class Error(val message: String) : PairingCompletionResult
}
