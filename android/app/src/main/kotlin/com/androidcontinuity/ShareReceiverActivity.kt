package com.androidcontinuity

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Parcelable
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import com.androidcontinuity.ui.share.DeviceSelectionSheet
import com.androidcontinuity.ui.share.PairingScreen
import com.androidcontinuity.ui.share.ScreenState
import com.androidcontinuity.ui.share.ShareScreen
import com.androidcontinuity.ui.share.ShareViewModel
import com.androidcontinuity.ui.share.TransferScreen
import com.androidcontinuity.ui.theme.AndroidContinuityTheme
import dagger.hilt.android.AndroidEntryPoint

/**
 * Activity launched by the Android share sheet when the user shares
 * images to "Send to Mac".
 *
 * Parses incoming [Intent.ACTION_SEND] / [Intent.ACTION_SEND_MULTIPLE]
 * intents to extract image URIs, then displays the [ShareScreen] where
 * the user picks a discovered Mac and sends the files.
 */
@AndroidEntryPoint
class ShareReceiverActivity : ComponentActivity() {

    companion object {
        private const val TAG = "ShareReceiver"
    }

    private val viewModel: ShareViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // Parse URIs from the share intent
        val imageUris = parseShareIntent(intent)
        Log.i(TAG, "Received ${imageUris.size} image URI(s)")

        if (imageUris.isEmpty()) {
            Log.w(TAG, "No image URIs found in intent, finishing")
            finish()
            return
        }

        viewModel.setImageUris(imageUris)

        setContent {
            AndroidContinuityTheme {
                val state by viewModel.uiState.collectAsState()
                val pairingState by viewModel.pairingState.collectAsState()
                val transferMessage by viewModel.transferMessage.collectAsState()

                when (state.screenState) {
                    ScreenState.Pairing -> {
                        PairingScreen(
                            state = pairingState,
                            deviceName = state.selectedDevice?.name ?: "Unknown",
                            onConfirmCode = viewModel::confirmPairingCode,
                            onCancel = viewModel::cancelPairing,
                            onRetry = viewModel::retryPairing,
                        )
                    }

                    ScreenState.Transferring, ScreenState.Done, ScreenState.Error -> {
                        TransferScreen(
                            screenState = state.screenState,
                            message = transferMessage,
                            imageCount = state.imageCount,
                            deviceName = state.selectedDevice?.name ?: "Mac",
                            onClose = { finish() },
                        )
                    }

                    else -> {
                        ShareScreen(
                            state = state,
                            onSelectDevice = viewModel::showDeviceSheet,
                            onSend = viewModel::startTransfer,
                            onClose = { finish() },
                        )
                    }
                }

                if (state.showDeviceSheet) {
                    DeviceSelectionSheet(
                        devices = state.discoveredDevices,
                        isDiscovering = state.isDiscovering,
                        selectedDevice = state.selectedDevice,
                        onDeviceSelected = viewModel::selectDevice,
                        onRefresh = viewModel::refreshDiscovery,
                        onDismiss = viewModel::hideDeviceSheet,
                    )
                }
            }
        }
    }

    /**
     * Extracts image [Uri]s from an incoming share intent.
     *
     * Handles both [Intent.ACTION_SEND] (single image) and
     * [Intent.ACTION_SEND_MULTIPLE] (multiple images).
     */
    private fun parseShareIntent(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()

        return when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                listOfNotNull(uri)
            }

            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                uris?.toList() ?: emptyList()
            }

            else -> {
                Log.w(TAG, "Unexpected intent action: ${intent.action}")
                emptyList()
            }
        }
    }
}
