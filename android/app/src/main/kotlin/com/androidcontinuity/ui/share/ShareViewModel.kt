package com.androidcontinuity.ui.share

import android.app.Application
import android.net.Uri
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.androidcontinuity.data.remote.PairingChallengeResult
import com.androidcontinuity.data.remote.PairingCompletionResult
import com.androidcontinuity.data.remote.PairingRepository
import com.androidcontinuity.data.remote.TransferProgress
import com.androidcontinuity.discovery.DiscoveredDevice
import com.androidcontinuity.discovery.NsdDiscoveryManager
import com.androidcontinuity.service.TransferForegroundService
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * ViewModel for the share flow.
 *
 * Manages image URIs from the share intent, mDNS device discovery,
 * user's device selection, pairing, and file transfer via foreground service.
 */
@HiltViewModel
class ShareViewModel @Inject constructor(
    private val application: Application,
    private val discoveryManager: NsdDiscoveryManager,
    private val pairingRepository: PairingRepository,
) : ViewModel() {

    companion object {
        private const val TAG = "ShareViewModel"
    }

    // ── Internal mutable state ──────────────────────────────────

    private val _imageUris = MutableStateFlow<List<Uri>>(emptyList())
    private val _selectedDevice = MutableStateFlow<DiscoveredDevice?>(null)
    private val _showDeviceSheet = MutableStateFlow(false)
    private val _screenState = MutableStateFlow(ScreenState.SelectingDevice)
    private val _pairingState = MutableStateFlow(PairingState())
    private val _transferMessage = MutableStateFlow("")

    // ── Public combined state ───────────────────────────────────

    private val dataFlows = combine(
        _imageUris,
        discoveryManager.devices,
        discoveryManager.isDiscovering,
    ) { uris, devices, discovering -> Triple(uris, devices, discovering) }

    private val uiFlows = combine(
        _selectedDevice,
        _showDeviceSheet,
        _screenState,
    ) { selected, showSheet, screen -> Triple(selected, showSheet, screen) }

    val uiState: StateFlow<ShareUiState> = combine(
        dataFlows,
        uiFlows,
    ) { (uris, devices, discovering), (selected, showSheet, screen) ->
        ShareUiState(
            imageUris = uris,
            discoveredDevices = devices,
            isDiscovering = discovering,
            selectedDevice = selected,
            showDeviceSheet = showSheet,
            screenState = screen,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5_000),
        initialValue = ShareUiState(),
    )

    val pairingState: StateFlow<PairingState> = _pairingState
    val transferMessage: StateFlow<String> = _transferMessage

    // ── Lifecycle ───────────────────────────────────────────────

    init {
        discoveryManager.startDiscovery()
        observeTransferProgress()
    }

    override fun onCleared() {
        super.onCleared()
        discoveryManager.stopDiscovery()
    }

    // ── Intent handling ─────────────────────────────────────────

    fun setImageUris(uris: List<Uri>) {
        _imageUris.value = uris
    }

    // ── Device selection ────────────────────────────────────────

    fun showDeviceSheet() {
        _showDeviceSheet.value = true
    }

    fun hideDeviceSheet() {
        _showDeviceSheet.value = false
    }

    fun selectDevice(device: DiscoveredDevice) {
        _selectedDevice.value = device
        _showDeviceSheet.value = false
    }

    fun clearSelection() {
        _selectedDevice.value = null
    }

    // ── Discovery control ───────────────────────────────────────

    fun refreshDiscovery() {
        discoveryManager.stopDiscovery()
        discoveryManager.startDiscovery()
    }

    // ── Pairing ─────────────────────────────────────────────────

    fun startPairing() {
        val device = _selectedDevice.value ?: return
        _pairingState.value = PairingState(step = PairingStep.Requesting)
        _screenState.value = ScreenState.Pairing

        viewModelScope.launch {
            when (val result = pairingRepository.requestPairing(device)) {
                is PairingChallengeResult.AlreadyTrusted -> {
                    Log.i(TAG, "Already trusted, proceeding to transfer")
                    _pairingState.value = PairingState(step = PairingStep.Paired)
                    launchTransferService()
                }

                is PairingChallengeResult.NeedsVerification -> {
                    _pairingState.value = PairingState(
                        step = PairingStep.VerifyingCode,
                        verificationCode = result.verificationCode,
                    )
                }

                is PairingChallengeResult.Denied -> {
                    _pairingState.value = PairingState(
                        step = PairingStep.Failed,
                        errorMessage = "Connection denied by Mac",
                    )
                }

                is PairingChallengeResult.Error -> {
                    _pairingState.value = PairingState(
                        step = PairingStep.Failed,
                        errorMessage = result.message,
                    )
                }
            }
        }
    }

    fun confirmPairingCode() {
        val device = _selectedDevice.value ?: return
        val code = _pairingState.value.verificationCode
        _pairingState.value = _pairingState.value.copy(step = PairingStep.Completing)

        viewModelScope.launch {
            when (val result = pairingRepository.completePairing(device, code)) {
                is PairingCompletionResult.Success -> {
                    Log.i(TAG, "Pairing succeeded, starting transfer")
                    _pairingState.value = PairingState(step = PairingStep.Paired)
                    launchTransferService()
                }

                is PairingCompletionResult.Timeout -> {
                    _pairingState.value = PairingState(
                        step = PairingStep.Failed,
                        errorMessage = "Approval timed out on Mac",
                    )
                }

                is PairingCompletionResult.Rejected -> {
                    _pairingState.value = PairingState(
                        step = PairingStep.Failed,
                        errorMessage = result.message,
                    )
                }

                is PairingCompletionResult.Error -> {
                    _pairingState.value = PairingState(
                        step = PairingStep.Failed,
                        errorMessage = result.message,
                    )
                }
            }
        }
    }

    fun cancelPairing() {
        _pairingState.value = PairingState()
        _screenState.value = ScreenState.SelectingDevice
    }

    fun retryPairing() {
        startPairing()
    }

    // ── Transfer ────────────────────────────────────────────────

    /**
     * Called when the user taps Send. Initiates pairing first if needed,
     * otherwise starts the file transfer directly.
     */
    fun startTransfer() {
        val device = _selectedDevice.value ?: return
        val uris = _imageUris.value
        if (uris.isEmpty()) return

        if (pairingRepository.sessionToken(forDevice = device) != null) {
            launchTransferService()
        } else {
            startPairing()
        }
    }

    private fun launchTransferService() {
        val device = _selectedDevice.value ?: return
        val uris = _imageUris.value
        if (uris.isEmpty()) return

        _screenState.value = ScreenState.Transferring
        _transferMessage.value = "Starting transfer..."

        val intent = TransferForegroundService.buildIntent(application, device, uris)
        application.startForegroundService(intent)
        Log.i(TAG, "Transfer service started for ${uris.size} file(s) to ${device.name}")
    }

    private fun observeTransferProgress() {
        viewModelScope.launch {
            TransferForegroundService.progress.collect { progress ->
                when (progress) {
                    is TransferProgress.Starting -> {
                        if (_screenState.value == ScreenState.Transferring) {
                            _transferMessage.value = "Connecting..."
                        }
                    }
                    is TransferProgress.Sending -> {
                        _screenState.value = ScreenState.Transferring
                        _transferMessage.value = "Sending ${progress.fileName} " +
                            "(${progress.fileIndex + 1}/${progress.totalFiles})"
                    }
                    is TransferProgress.Done -> {
                        _screenState.value = ScreenState.Done
                        _transferMessage.value = "${progress.fileCount} file(s) sent successfully"
                    }
                    is TransferProgress.Error -> {
                        _screenState.value = ScreenState.Error
                        _transferMessage.value = progress.message
                    }
                }
            }
        }
    }
}
