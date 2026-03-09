package com.androidcontinuity.ui.share

/**
 * UI state for the pairing flow, managed as part of [ShareViewModel].
 */
data class PairingState(
    /** Current step in the pairing flow. */
    val step: PairingStep = PairingStep.Idle,

    /** Verification code received from the Mac. */
    val verificationCode: String = "",

    /** Error message if pairing failed. */
    val errorMessage: String? = null,
)

enum class PairingStep {
    /** No pairing in progress. */
    Idle,

    /** Requesting pairing from the Mac (loading). */
    Requesting,

    /** Showing verification code — user must confirm it matches. */
    VerifyingCode,

    /** Completing pairing after user confirmed the code. */
    Completing,

    /** Pairing succeeded. */
    Paired,

    /** Pairing failed. */
    Failed,
}
