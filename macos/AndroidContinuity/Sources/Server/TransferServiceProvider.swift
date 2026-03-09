import Foundation
import GRPCCore
import OSLog

/// Server-side implementation of the TransferService gRPC service.
///
/// Receives files from Android via client-streaming `SendFile` RPC,
/// writes chunks to temp files, and atomically moves them to the
/// user's download folder on completion.
struct TransferServiceProvider: ACTransferService.SimpleServiceProtocol {

    private static let logger = Logger(subsystem: "com.androidcontinuity", category: "Transfer")

    /// Closure to get the download folder from SettingsStore on MainActor.
    private let getDownloadFolder: @Sendable () async -> URL

    /// Closure to verify a session token via PairingManager.
    private let verifySession: @Sendable (String, String) async -> Bool

    /// Called when a file is successfully received and saved.
    private let onFileReceived: @Sendable (String) async -> Void

    /// Tracks active transfers: transfer_id → metadata.
    private let transfers = TransferStore()

    init(
        downloadFolder: @escaping @Sendable () async -> URL = {
            await MainActor.run { SettingsStore.shared.effectiveDownloadFolder }
        },
        verifySession: @escaping @Sendable (String, String) async -> Bool = { _, _ in true },
        onFileReceived: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.getDownloadFolder = downloadFolder
        self.verifySession = verifySession
        self.onFileReceived = onFileReceived
    }

    // MARK: - InitiateTransfer

    func initiateTransfer(
        request: ACTransferRequest,
        context: GRPCCore.ServerContext
    ) async throws -> ACTransferResponse {
        let fileCount = request.files.count
        let deviceId = request.senderDeviceID
        Self.logger.info("Transfer initiated: \(fileCount) file(s) from '\(deviceId)'")

        // Verify session
        let valid = await verifySession(deviceId, request.sessionToken)
        guard valid else {
            Self.logger.warning("Invalid session for transfer from '\(deviceId)'")
            var response = ACTransferResponse()
            response.status = .rejected
            response.message = "Invalid or expired session"
            return response
        }

        let transferId = UUID().uuidString

        // Build file metadata map
        var fileMeta: [String: TransferFileMeta] = [:]
        var acceptances: [ACFileAcceptance] = []

        for file in request.files {
            fileMeta[file.fileID] = TransferFileMeta(
                fileId: file.fileID,
                fileName: file.fileName,
                mimeType: file.mimeType,
                totalBytes: file.fileSize,
                checksumSha256: file.checksumSha256
            )

            var acceptance = ACFileAcceptance()
            acceptance.fileID = file.fileID
            acceptance.accepted = true
            acceptances.append(acceptance)
        }

        await transfers.register(
            transferId: transferId,
            deviceId: deviceId,
            files: fileMeta
        )

        var response = ACTransferResponse()
        response.status = .ok
        response.transferID = transferId
        response.fileAcceptances = acceptances
        response.message = "Ready to receive \(fileCount) file(s)"

        Self.logger.info("Transfer \(transferId) ready for \(fileCount) file(s)")
        return response
    }

    // MARK: - SendFile (client streaming)

    func sendFile(
        request: GRPCCore.RPCAsyncSequence<ACFileChunk, any Swift.Error>,
        context: GRPCCore.ServerContext
    ) async throws -> ACFileReceipt {
        let downloadFolder = await getDownloadFolder()
        let fileReceiver = FileReceiver(destinationFolder: downloadFolder)

        var currentFileId = ""
        var currentTransferId = ""
        var totalBytes: Int64 = 0
        var fileStarted = false

        for try await chunk in request {
            currentFileId = chunk.fileID
            currentTransferId = chunk.transferID

            // Get the original file name from transfer metadata
            let fileName = await transfers.fileName(
                transferId: currentTransferId,
                fileId: currentFileId
            ) ?? "\(currentFileId).bin"

            // Start receiving if first chunk
            if !fileStarted {
                _ = try fileReceiver.beginReceiving(fileId: currentFileId, fileName: fileName)
                fileStarted = true
                Self.logger.info("Receiving file '\(fileName)' (id: \(currentFileId))")
            }

            // Write chunk data
            try fileReceiver.writeChunk(fileId: currentFileId, data: chunk.data)
            totalBytes += Int64(chunk.data.count)

            // Update progress
            await transfers.updateProgress(
                transferId: currentTransferId,
                fileId: currentFileId,
                bytesReceived: totalBytes
            )

            // Finalise on last chunk
            if chunk.isLastChunk {
                let finalURL = try fileReceiver.finishReceiving(
                    fileId: currentFileId,
                    fileName: fileName
                )
                Self.logger.info("File saved: \(finalURL.lastPathComponent) (\(totalBytes) bytes)")
                await onFileReceived(finalURL.lastPathComponent)

                await transfers.markFileCompleted(
                    transferId: currentTransferId,
                    fileId: currentFileId
                )
            }
        }

        var receipt = ACFileReceipt()
        receipt.transferID = currentTransferId
        receipt.fileID = currentFileId
        receipt.status = .ok
        receipt.bytesReceived = totalBytes
        receipt.checksumVerified = false // TODO: SHA-256 verification
        receipt.message = "File received successfully"

        Self.logger.info("SendFile complete: \(currentFileId) — \(totalBytes) bytes")
        return receipt
    }

    // MARK: - GetTransferStatus

    func getTransferStatus(
        request: ACTransferStatusRequest,
        context: GRPCCore.ServerContext
    ) async throws -> ACTransferStatusResponse {
        Self.logger.info("Status requested for transfer '\(request.transferID)'")

        let info = await transfers.info(transferId: request.transferID)

        var response = ACTransferStatusResponse()
        response.transferID = request.transferID

        if let info = info {
            response.state = info.allCompleted ? .completed : .inProgress
            response.fileProgress = info.files.map { file in
                var progress = ACFileProgress()
                progress.fileID = file.fileId
                progress.bytesTransferred = file.bytesReceived
                progress.totalBytes = file.totalBytes
                progress.state = file.completed ? .completed : .inProgress
                return progress
            }
        } else {
            response.state = .unspecified
            response.message = "Transfer not found"
        }

        return response
    }

    // MARK: - CancelTransfer

    func cancelTransfer(
        request: ACCancelTransferRequest,
        context: GRPCCore.ServerContext
    ) async throws -> ACCancelTransferResponse {
        Self.logger.info("Transfer cancelled: '\(request.transferID)' — \(request.reason)")
        await transfers.remove(transferId: request.transferID)

        var response = ACCancelTransferResponse()
        response.status = .ok
        return response
    }
}

// MARK: - Transfer tracking

/// Thread-safe storage for active transfers (actor-isolated).
private actor TransferStore {
    private var transfers: [String: TransferInfo] = [:]

    func register(transferId: String, deviceId: String, files: [String: TransferFileMeta]) {
        transfers[transferId] = TransferInfo(
            transferId: transferId,
            deviceId: deviceId,
            files: files.values.map { FileProg(fileId: $0.fileId, fileName: $0.fileName, totalBytes: $0.totalBytes) }
        )
    }

    func fileName(transferId: String, fileId: String) -> String? {
        transfers[transferId]?.files.first { $0.fileId == fileId }?.fileName
    }

    func updateProgress(transferId: String, fileId: String, bytesReceived: Int64) {
        guard var info = transfers[transferId],
              let idx = info.files.firstIndex(where: { $0.fileId == fileId }) else { return }
        info.files[idx].bytesReceived = bytesReceived
        transfers[transferId] = info
    }

    func markFileCompleted(transferId: String, fileId: String) {
        guard var info = transfers[transferId],
              let idx = info.files.firstIndex(where: { $0.fileId == fileId }) else { return }
        info.files[idx].completed = true
        transfers[transferId] = info
    }

    func info(transferId: String) -> TransferInfo? {
        transfers[transferId]
    }

    func remove(transferId: String) {
        transfers.removeValue(forKey: transferId)
    }
}

struct TransferInfo {
    let transferId: String
    let deviceId: String
    var files: [FileProg]

    var allCompleted: Bool { files.allSatisfy(\.completed) }
}

struct FileProg {
    let fileId: String
    let fileName: String
    let totalBytes: Int64
    var bytesReceived: Int64 = 0
    var completed: Bool = false
}

struct TransferFileMeta {
    let fileId: String
    let fileName: String
    let mimeType: String
    let totalBytes: Int64
    let checksumSha256: Data
}
