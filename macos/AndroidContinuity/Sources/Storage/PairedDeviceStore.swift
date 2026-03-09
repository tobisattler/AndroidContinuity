import Foundation

final class PairedDeviceStore: ObservableObject {
    private static let storageKey = "pairedDevices"

    @Published private(set) var devices: [PairedDevice] = []

    init() {
        load()
    }

    func addDevice(_ device: PairedDevice) {
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        save()
    }

    func removeDevice(withId id: String) {
        devices.removeAll { $0.id == id }
        save()
    }

    func device(withId id: String) -> PairedDevice? {
        devices.first { $0.id == id }
    }

    func updateLastSeen(deviceId: String) {
        guard let index = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[index].lastSeenDate = Date()
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([PairedDevice].self, from: data)
        else { return }
        devices = decoded
    }
}
