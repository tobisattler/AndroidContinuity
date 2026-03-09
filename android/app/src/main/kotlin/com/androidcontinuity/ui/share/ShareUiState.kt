package com.androidcontinuity.ui.share

import android.net.Uri
import com.androidcontinuity.discovery.DiscoveredDevice

/**
 * UI state for the share flow.
 */
data class ShareUiState(
    /** URIs of the images the user wants to send. */
    val imageUris: List<Uri> = emptyList(),

    /** Discovered Macs on the local network. */
    val discoveredDevices: List<DiscoveredDevice> = emptyList(),

    /** Whether mDNS discovery is active. */
    val isDiscovering: Boolean = false,

    /** The device the user selected (null = none yet). */
    val selectedDevice: DiscoveredDevice? = null,

    /** Whether the device-selection bottom sheet is visible. */
    val showDeviceSheet: Boolean = false,

    /** Overall screen state. */
    val screenState: ScreenState = ScreenState.SelectingDevice,
) {
    val imageCount: Int get() = imageUris.size

    /** True when there's at least one image and a target device. */
    val canSend: Boolean
        get() = imageUris.isNotEmpty() && selectedDevice != null
}

enum class ScreenState {
    /** User is picking which Mac to send to. */
    SelectingDevice,

    /** Pairing in progress (verification code flow). */
    Pairing,

    /** Transfer is in progress (future Phase 5). */
    Transferring,

    /** Transfer completed successfully. */
    Done,

    /** An error occurred. */
    Error,
}
