import SwiftUI

struct TransferProgressView: View {
    let fileName: String
    let progress: Double
    let totalFiles: Int
    let currentFile: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Receiving files...")
                .font(.headline)

            Text("\(currentFile) of \(totalFiles): \(fileName)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            ProgressView(value: progress)
                .progressViewStyle(.linear)

            Text("\(Int(progress * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 280)
    }
}
