import Foundation
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @AppStorage("downloadFolder") var downloadFolder: String = ""

    var downloadFolderURL: URL? {
        guard !downloadFolder.isEmpty else { return nil }
        return URL(filePath: downloadFolder)
    }

    var effectiveDownloadFolder: URL {
        downloadFolderURL ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }
}
