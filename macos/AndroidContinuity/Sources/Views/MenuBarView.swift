import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "arrow.triangle.swap")
                    .foregroundStyle(.blue)
                Text("AndroidContinuity")
                    .font(.headline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Status section
            VStack(alignment: .leading, spacing: 4) {
                StatusRow(
                    label: "Server",
                    state: serverStatusIcon,
                    detail: serverDetail
                )
                StatusRow(
                    label: "Network",
                    state: bonjourStatusIcon,
                    detail: bonjourDetail
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Actions
            if appState.isRunning {
                Button {
                    appState.stopServices()
                } label: {
                    Label("Stop Services", systemImage: "stop.circle")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            } else {
                Button {
                    appState.startServices()
                } label: {
                    Label("Start Services", systemImage: "play.circle")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // Recent transfers
            if !appState.recentFiles.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Transfers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 2)

                    ForEach(appState.recentFiles.prefix(3), id: \.self) { name in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text(name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    if appState.recentFiles.count > 3 {
                        Text("+\(appState.recentFiles.count - 3) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            Divider()

            Button {
                NSWorkspace.shared.open(appState.settingsStore.effectiveDownloadFolder)
            } label: {
                Label("Open Downloads Folder", systemImage: "folder")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            SettingsLink {
                Label("Settings...", systemImage: "gear")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .padding(.vertical, 4)
        .frame(width: 260)
        .task {
            // Auto-start services on app launch
            if !appState.isRunning {
                appState.startServices()
            }
        }
        .onChange(of: appState.pairingManager.pendingRequest?.id) { _, newValue in
            if newValue != nil {
                openWindow(id: "pairing-approval")
            }
        }
    }

    // MARK: - Computed helpers

    private var serverStatusIcon: StatusRow.StatusIndicator {
        switch appState.grpcServer.state {
        case .running: return .active
        case .starting: return .loading
        case .failed: return .error
        case .stopped: return .inactive
        }
    }

    private var serverDetail: String {
        switch appState.grpcServer.state {
        case .running(let port): return "Port \(port)"
        case .starting: return "Starting..."
        case .failed(let msg): return msg
        case .stopped: return "Stopped"
        }
    }

    private var bonjourStatusIcon: StatusRow.StatusIndicator {
        switch appState.bonjourAdvertiser.state {
        case .advertising: return .active
        case .starting: return .loading
        case .failed: return .error
        case .stopped: return .inactive
        }
    }

    private var bonjourDetail: String {
        switch appState.bonjourAdvertiser.state {
        case .advertising: return "Discoverable"
        case .starting: return "Starting..."
        case .failed(let msg): return msg
        case .stopped: return "Not advertising"
        }
    }
}

// MARK: - Status Row Component

struct StatusRow: View {
    enum StatusIndicator {
        case active, loading, error, inactive

        var color: Color {
            switch self {
            case .active: return .green
            case .loading: return .orange
            case .error: return .red
            case .inactive: return .gray
            }
        }
    }

    let label: String
    let state: StatusIndicator
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)

            Spacer()

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
