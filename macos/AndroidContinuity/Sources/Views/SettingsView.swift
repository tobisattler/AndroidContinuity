import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var pairedDeviceStore: PairedDeviceStore

    var body: some View {
        TabView {
            GeneralSettingsView(settingsStore: settingsStore)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            DeviceManagementView(pairedDeviceStore: pairedDeviceStore)
                .tabItem {
                    Label("Devices", systemImage: "iphone.and.arrow.forward")
                }
        }
        .frame(width: 500, height: 320)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("File Transfer") {
                LabeledContent("Download Folder") {
                    HStack {
                        Text(displayPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !settingsStore.downloadFolder.isEmpty {
                            Button("Show") {
                                if let url = settingsStore.downloadFolderURL {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }

                        Button("Choose...") {
                            chooseDownloadFolder()
                        }
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var displayPath: String {
        if settingsStore.downloadFolder.isEmpty {
            return "~/Downloads (default)"
        }
        return settingsStore.downloadFolder
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for incoming file transfers"
        panel.directoryURL = settingsStore.effectiveDownloadFolder

        if panel.runModal() == .OK, let url = panel.url {
            settingsStore.downloadFolder = url.path(percentEncoded: false)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Silently fail — common in debug builds / unsigned apps
        }
    }
}

// MARK: - Device Management

struct DeviceManagementView: View {
    @ObservedObject var pairedDeviceStore: PairedDeviceStore
    @State private var selectedDeviceId: String?

    var body: some View {
        VStack(spacing: 0) {
            if pairedDeviceStore.devices.isEmpty {
                ContentUnavailableView {
                    Label("No Paired Devices", systemImage: "iphone.slash")
                } description: {
                    Text("Devices will appear here after pairing with an Android phone.")
                }
            } else {
                List(pairedDeviceStore.devices, selection: $selectedDeviceId) { device in
                    DeviceRow(device: device)
                }

                Divider()

                HStack {
                    Spacer()
                    Button("Remove", role: .destructive) {
                        if let id = selectedDeviceId {
                            pairedDeviceStore.removeDevice(withId: id)
                            selectedDeviceId = nil
                        }
                    }
                    .disabled(selectedDeviceId == nil)
                }
                .padding(8)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct DeviceRow: View {
    let device: PairedDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: deviceIcon)
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    Text(trustBadge)
                        .font(.caption)
                        .foregroundStyle(device.trustLevel == .always ? .green : .orange)

                    Text("Last seen: \(device.lastSeenDate.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var deviceIcon: String {
        device.deviceType == "android" ? "smartphone" : "laptopcomputer"
    }

    private var trustBadge: String {
        device.trustLevel == .always ? "Always Allowed" : "One-Time"
    }
}
