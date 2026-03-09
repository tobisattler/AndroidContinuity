import Foundation

struct TransferSession: Identifiable {
    let id: String          // transfer_id
    let senderDeviceId: String
    let senderDeviceName: String
    let files: [TransferFile]
    var state: TransferState
    let startedAt: Date

    struct TransferFile: Identifiable {
        let id: String      // file_id
        let fileName: String
        let mimeType: String
        let totalBytes: Int64
        var bytesReceived: Int64
        var state: TransferState
    }

    enum TransferState {
        case pending
        case inProgress
        case completed
        case failed(String)
        case cancelled
    }
}
