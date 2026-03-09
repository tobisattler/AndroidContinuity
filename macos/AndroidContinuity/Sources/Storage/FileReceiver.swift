import Foundation

final class FileReceiver {
    private let destinationFolder: URL
    private var activeFiles: [String: FileHandle] = [:]
    private var tempURLs: [String: URL] = [:]

    init(destinationFolder: URL) {
        self.destinationFolder = destinationFolder
    }

    func beginReceiving(fileId: String, fileName: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        activeFiles[fileId] = handle
        tempURLs[fileId] = tempURL
        return tempURL
    }

    func writeChunk(fileId: String, data: Data) throws {
        guard let handle = activeFiles[fileId] else {
            throw FileReceiverError.noActiveFile(fileId)
        }
        try handle.write(contentsOf: data)
    }

    func finishReceiving(fileId: String, fileName: String) throws -> URL {
        guard let handle = activeFiles[fileId],
              let tempURL = tempURLs[fileId] else {
            throw FileReceiverError.noActiveFile(fileId)
        }

        try handle.close()
        activeFiles.removeValue(forKey: fileId)
        tempURLs.removeValue(forKey: fileId)

        let finalURL = uniqueURL(for: fileName, in: destinationFolder)
        try FileManager.default.moveItem(at: tempURL, to: finalURL)

        return finalURL
    }

    func cancelReceiving(fileId: String) {
        if let handle = activeFiles.removeValue(forKey: fileId) {
            try? handle.close()
        }
        if let tempURL = tempURLs.removeValue(forKey: fileId) {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private func uniqueURL(for fileName: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return url
        }

        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var counter = 1

        repeat {
            let newName = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
            url = folder.appendingPathComponent(newName)
            counter += 1
        } while FileManager.default.fileExists(atPath: url.path(percentEncoded: false))

        return url
    }
}

enum FileReceiverError: Error {
    case noActiveFile(String)
}
