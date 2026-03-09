package com.androidcontinuity.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.androidcontinuity.data.remote.TransferProgress
import com.androidcontinuity.data.remote.TransferRepository
import com.androidcontinuity.discovery.DiscoveredDevice
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Foreground service that handles file transfers to a Mac.
 *
 * Shows a persistent notification with transfer progress.
 * Keeps the process alive even when the share activity finishes.
 */
@AndroidEntryPoint
class TransferForegroundService : Service() {

    companion object {
        private const val TAG = "TransferService"
        private const val CHANNEL_ID = "transfer_channel"
        private const val NOTIFICATION_ID = 1001

        private const val EXTRA_DEVICE_NAME = "device_name"
        private const val EXTRA_DEVICE_HOST = "device_host"
        private const val EXTRA_DEVICE_PORT = "device_port"
        private const val EXTRA_DEVICE_SERVICE_NAME = "device_service_name"
        private const val EXTRA_URIS = "image_uris"

        /** Observable transfer state for UI binding. */
        private val _progress = MutableStateFlow<TransferProgress>(TransferProgress.Starting)
        val progress: StateFlow<TransferProgress> = _progress.asStateFlow()

        fun buildIntent(
            context: Context,
            device: DiscoveredDevice,
            uris: List<Uri>,
        ): Intent = Intent(context, TransferForegroundService::class.java).apply {
            putExtra(EXTRA_DEVICE_NAME, device.name)
            putExtra(EXTRA_DEVICE_HOST, device.host)
            putExtra(EXTRA_DEVICE_PORT, device.grpcPort)
            putExtra(EXTRA_DEVICE_SERVICE_NAME, device.serviceName)
            putParcelableArrayListExtra(EXTRA_URIS, ArrayList(uris))
        }
    }

    @Inject lateinit var transferRepository: TransferRepository

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        val device = DiscoveredDevice(
            name = intent.getStringExtra(EXTRA_DEVICE_NAME) ?: "Mac",
            host = intent.getStringExtra(EXTRA_DEVICE_HOST) ?: "",
            grpcPort = intent.getIntExtra(EXTRA_DEVICE_PORT, 50051),
            serviceName = intent.getStringExtra(EXTRA_DEVICE_SERVICE_NAME) ?: "",
        )

        @Suppress("DEPRECATION")
        val uris: List<Uri> = intent.getParcelableArrayListExtra(EXTRA_URIS) ?: emptyList()

        if (uris.isEmpty() || device.host.isEmpty()) {
            Log.w(TAG, "Missing device or URIs, stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        // Start foreground immediately
        startForeground(NOTIFICATION_ID, buildProgressNotification("Preparing transfer...", 0))

        Log.i(TAG, "Starting transfer of ${uris.size} file(s) to ${device.name}")
        startTransfer(device, uris, contentResolver)

        return START_NOT_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        serviceScope.cancel()
    }

    private fun startTransfer(
        device: DiscoveredDevice,
        uris: List<Uri>,
        resolver: ContentResolver,
    ) {
        serviceScope.launch {
            transferRepository.transfer(device, uris, resolver)
                .catch { e ->
                    Log.e(TAG, "Transfer flow error", e)
                    _progress.value = TransferProgress.Error(e.message ?: "Unknown error")
                    updateNotification("Transfer failed", -1)
                    stopSelf()
                }
                .collect { progress ->
                    _progress.value = progress
                    when (progress) {
                        is TransferProgress.Starting -> {
                            updateNotification("Connecting...", 0)
                        }
                        is TransferProgress.Sending -> {
                            val percent = if (progress.totalBytes > 0) {
                                ((progress.bytesSent * 100) / progress.totalBytes).toInt()
                            } else {
                                0
                            }
                            val text = "Sending ${progress.fileName} (${progress.fileIndex + 1}/${progress.totalFiles})"
                            updateNotification(text, percent)
                        }
                        is TransferProgress.Done -> {
                            updateNotification("${progress.fileCount} file(s) sent", 100)
                            stopSelf()
                        }
                        is TransferProgress.Error -> {
                            updateNotification("Transfer failed", -1)
                            stopSelf()
                        }
                    }
                }
        }
    }

    // MARK: - Notification

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "File Transfers",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shows progress while transferring files to Mac"
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }

    private fun buildProgressNotification(text: String, progress: Int): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_upload)
            .setContentTitle("AndroidContinuity")
            .setContentText(text)
            .setOngoing(true)
            .setSilent(true)

        if (progress in 0..99) {
            builder.setProgress(100, progress, false)
        } else if (progress < 0) {
            builder.setOngoing(false)
        } else {
            builder.setProgress(0, 0, false)
            builder.setOngoing(false)
        }

        return builder.build()
    }

    private fun updateNotification(text: String, progress: Int) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildProgressNotification(text, progress))
    }
}
