package com.androidcontinuity.data.remote

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import com.androidcontinuity.discovery.DiscoveredDevice
import com.androidcontinuity.proto.FileChunk
import com.androidcontinuity.proto.FileMetadata
import com.androidcontinuity.proto.FileReceipt
import com.androidcontinuity.proto.StatusCode
import com.androidcontinuity.proto.TransferDirection
import com.androidcontinuity.proto.TransferRequest
import com.androidcontinuity.proto.TransferResponse
import com.androidcontinuity.proto.TransferServiceGrpcKt.TransferServiceCoroutineStub
import com.google.protobuf.ByteString
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages file transfer to a Mac over gRPC.
 *
 * Flow:
 * 1. [transfer] sends file metadata via InitiateTransfer, receives acceptance per file
 * 2. For each accepted file, streams 64 KB chunks via client-streaming SendFile RPC
 *
 * Emits [TransferProgress] so the UI can show a progress bar.
 */
@Singleton
class TransferRepository @Inject constructor(
    private val channelProvider: GrpcChannelProvider,
    private val pairingRepository: PairingRepository,
) {
    companion object {
        private const val TAG = "TransferRepo"
        private const val CHUNK_SIZE = 64 * 1024 // 64 KB
    }

    /**
     * Execute the full transfer flow for a list of image URIs to a device.
     */
    fun transfer(
        device: DiscoveredDevice,
        uris: List<Uri>,
        contentResolver: ContentResolver,
    ): Flow<TransferProgress> = flow {
        emit(TransferProgress.Starting)

        val sessionToken = pairingRepository.sessionToken(forDevice = device)
        if (sessionToken == null) {
            emit(TransferProgress.Error("Not paired — no session token"))
            return@flow
        }

        val stub = TransferServiceCoroutineStub(channelProvider.channelFor(device))

        // Build file metadata for each URI
        val fileMetas = uris.map { uri -> buildFileMetadata(uri, contentResolver) }

        // Step 1: Initiate transfer
        val request = TransferRequest.newBuilder()
            .setSessionToken(sessionToken)
            .setSenderDeviceId(pairingRepository.deviceId)
            .addAllFiles(fileMetas.map { it.proto })
            .setDirection(TransferDirection.TRANSFER_DIRECTION_ANDROID_TO_MACOS)
            .build()

        val initResponse: TransferResponse = try {
            stub.initiateTransfer(request)
        } catch (e: Exception) {
            Log.e(TAG, "InitiateTransfer failed", e)
            emit(TransferProgress.Error("Failed to initiate transfer: ${e.message}"))
            return@flow
        }

        if (initResponse.status != StatusCode.STATUS_CODE_OK) {
            emit(TransferProgress.Error(initResponse.message.ifEmpty { "Transfer rejected" }))
            return@flow
        }

        val transferId = initResponse.transferId
        Log.i(TAG, "Transfer $transferId initiated for ${fileMetas.size} file(s)")

        // Build set of accepted file IDs
        val acceptedIds = initResponse.fileAcceptancesList
            .filter { it.accepted }
            .map { it.fileId }
            .toSet()

        val totalFiles = acceptedIds.size
        var completedFiles = 0

        // Step 2: Send each accepted file via client-streaming RPC
        for (meta in fileMetas) {
            if (meta.fileId !in acceptedIds) {
                Log.w(TAG, "File '${meta.fileName}' was rejected, skipping")
                continue
            }

            emit(
                TransferProgress.Sending(
                    fileName = meta.fileName,
                    fileIndex = completedFiles,
                    totalFiles = totalFiles,
                    bytesSent = 0L,
                    totalBytes = meta.fileSize,
                )
            )

            val receipt: FileReceipt = try {
                stub.sendFile(
                    buildChunkFlow(
                        transferId = transferId,
                        fileId = meta.fileId,
                        uri = meta.uri,
                        fileSize = meta.fileSize,
                        contentResolver = contentResolver,
                    )
                )
            } catch (e: Exception) {
                Log.e(TAG, "SendFile failed for '${meta.fileName}'", e)
                emit(TransferProgress.Error("Failed to send '${meta.fileName}': ${e.message}"))
                return@flow
            }

            if (receipt.status != StatusCode.STATUS_CODE_OK) {
                emit(TransferProgress.Error("Mac rejected '${meta.fileName}': ${receipt.message}"))
                return@flow
            }

            completedFiles++
            Log.i(TAG, "File '${meta.fileName}' sent (${receipt.bytesReceived} bytes)")
            emit(
                TransferProgress.Sending(
                    fileName = meta.fileName,
                    fileIndex = completedFiles - 1,
                    totalFiles = totalFiles,
                    bytesSent = meta.fileSize,
                    totalBytes = meta.fileSize,
                )
            )
        }

        emit(TransferProgress.Done(fileCount = completedFiles))
        Log.i(TAG, "Transfer $transferId completed: $completedFiles file(s)")
    }

    // MARK: - Helpers

    /**
     * Produces a [Flow] of [FileChunk] messages by reading the content URI in 64 KB pieces.
     */
    private fun buildChunkFlow(
        transferId: String,
        fileId: String,
        uri: Uri,
        fileSize: Long,
        contentResolver: ContentResolver,
    ): Flow<FileChunk> = flow {
        contentResolver.openInputStream(uri)?.use { inputStream ->
            val buffer = ByteArray(CHUNK_SIZE)
            var chunkIndex = 0
            var totalSent = 0L
            val totalChunks = if (fileSize > 0) {
                ((fileSize + CHUNK_SIZE - 1) / CHUNK_SIZE).toInt()
            } else {
                0 // unknown
            }

            while (true) {
                val bytesRead = inputStream.read(buffer)
                if (bytesRead == -1) break

                totalSent += bytesRead
                val isLast = if (fileSize > 0) totalSent >= fileSize else bytesRead < CHUNK_SIZE

                val chunk = FileChunk.newBuilder()
                    .setTransferId(transferId)
                    .setFileId(fileId)
                    .setChunkIndex(chunkIndex)
                    .setData(ByteString.copyFrom(buffer, 0, bytesRead))
                    .setIsLastChunk(isLast)
                    .setTotalChunks(totalChunks)
                    .build()

                emit(chunk)
                chunkIndex++

                if (isLast) break
            }

            // Edge case: empty file
            if (chunkIndex == 0) {
                emit(
                    FileChunk.newBuilder()
                        .setTransferId(transferId)
                        .setFileId(fileId)
                        .setChunkIndex(0)
                        .setData(ByteString.EMPTY)
                        .setIsLastChunk(true)
                        .setTotalChunks(1)
                        .build()
                )
            }
        } ?: throw IllegalStateException("Could not open input stream for $uri")
    }

    private fun buildFileMetadata(uri: Uri, contentResolver: ContentResolver): FileMeta {
        val fileName = getFileName(uri, contentResolver) ?: "image_${UUID.randomUUID()}.jpg"
        val mimeType = contentResolver.getType(uri) ?: "application/octet-stream"
        val fileSize = getFileSize(uri, contentResolver)
        val fileId = UUID.randomUUID().toString()

        val proto = FileMetadata.newBuilder()
            .setFileId(fileId)
            .setFileName(fileName)
            .setMimeType(mimeType)
            .setFileSize(fileSize)
            .setCreatedAtMillis(System.currentTimeMillis())
            .build()

        return FileMeta(
            fileId = fileId,
            fileName = fileName,
            mimeType = mimeType,
            fileSize = fileSize,
            uri = uri,
            proto = proto,
        )
    }

    private fun getFileName(uri: Uri, contentResolver: ContentResolver): String? {
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) return cursor.getString(idx)
            }
        }
        return uri.lastPathSegment
    }

    private fun getFileSize(uri: Uri, contentResolver: ContentResolver): Long {
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (idx >= 0) return cursor.getLong(idx)
            }
        }
        return 0L
    }

    private data class FileMeta(
        val fileId: String,
        val fileName: String,
        val mimeType: String,
        val fileSize: Long,
        val uri: Uri,
        val proto: FileMetadata,
    )
}

/** Progress updates emitted during a transfer. */
sealed interface TransferProgress {
    data object Starting : TransferProgress
    data class Sending(
        val fileName: String,
        val fileIndex: Int,
        val totalFiles: Int,
        val bytesSent: Long,
        val totalBytes: Long,
    ) : TransferProgress
    data class Done(val fileCount: Int) : TransferProgress
    data class Error(val message: String) : TransferProgress
}
