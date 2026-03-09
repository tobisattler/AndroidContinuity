import Foundation

struct PairedDevice: Identifiable, Codable {
    let id: String          // device_id from proto
    let name: String
    let deviceType: String  // "android" | "macos"
    let trustLevel: TrustLevel
    let firstSeenDate: Date
    var lastSeenDate: Date
    var sessionToken: String?

    enum TrustLevel: String, Codable {
        case once
        case always
    }
}
