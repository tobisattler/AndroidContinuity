import Foundation
import XCTest

@testable import AndroidContinuity

// MARK: - FileReceiver Tests

final class FileReceiverTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWritesFileToDestination() throws {
        let receiver = FileReceiver(destinationFolder: tempDir)

        _ = try receiver.beginReceiving(fileId: "f1", fileName: "photo.jpg")
        try receiver.writeChunk(fileId: "f1", data: Data([0x89, 0x50, 0x4E, 0x47]))
        try receiver.writeChunk(fileId: "f1", data: Data([0x0D, 0x0A, 0x1A, 0x0A]))
        let finalURL = try receiver.finishReceiving(fileId: "f1", fileName: "photo.jpg")

        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false)))
        let data = try Data(contentsOf: finalURL)
        XCTAssertEqual(data.count, 8)
        XCTAssertEqual(finalURL.lastPathComponent, "photo.jpg")
    }

    func testUniqueNaming() throws {
        let receiver = FileReceiver(destinationFolder: tempDir)

        _ = try receiver.beginReceiving(fileId: "f1", fileName: "test.jpg")
        try receiver.writeChunk(fileId: "f1", data: Data([1, 2, 3]))
        let url1 = try receiver.finishReceiving(fileId: "f1", fileName: "test.jpg")

        _ = try receiver.beginReceiving(fileId: "f2", fileName: "test.jpg")
        try receiver.writeChunk(fileId: "f2", data: Data([4, 5, 6]))
        let url2 = try receiver.finishReceiving(fileId: "f2", fileName: "test.jpg")

        XCTAssertEqual(url1.lastPathComponent, "test.jpg")
        XCTAssertEqual(url2.lastPathComponent, "test (1).jpg")
    }

    func testCancelRemovesTempFile() throws {
        let receiver = FileReceiver(destinationFolder: tempDir)

        _ = try receiver.beginReceiving(fileId: "c1", fileName: "nope.jpg")
        try receiver.writeChunk(fileId: "c1", data: Data([0xFF]))
        receiver.cancelReceiving(fileId: "c1")

        let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        XCTAssertTrue(contents.isEmpty)
    }
}

// MARK: - PairingManager Tests

@MainActor
final class PairingManagerTests: XCTestCase {

    func testGeneratesValidVerificationCode() {
        let store = PairedDeviceStore()
        let manager = PairingManager(deviceStore: store)
        let code = manager.generateVerificationCode()
        XCTAssertEqual(code.count, 6)
        XCTAssertNotNil(Int(code))
        XCTAssertGreaterThanOrEqual(Int(code)!, 100_000)
        XCTAssertLessThanOrEqual(Int(code)!, 999_999)
    }

    func testGeneratesUniqueSessionTokens() {
        let store = PairedDeviceStore()
        let manager = PairingManager(deviceStore: store)
        let token1 = manager.generateSessionToken()
        let token2 = manager.generateSessionToken()
        XCTAssertNotEqual(token1, token2)
        XCTAssertFalse(token1.isEmpty)
    }

    func testCreatesChallengeAndSetsPendingRequest() {
        let store = PairedDeviceStore()
        let manager = PairingManager(deviceStore: store)

        XCTAssertNil(manager.pendingRequest)

        let (code, nonce) = manager.createChallenge(
            deviceId: "test-device",
            deviceName: "Test Phone",
            deviceType: "android"
        )

        XCTAssertEqual(code.count, 6)
        XCTAssertEqual(nonce.count, 32)
        XCTAssertNotNil(manager.pendingRequest)
        XCTAssertEqual(manager.pendingRequest?.deviceId, "test-device")
        XCTAssertEqual(manager.pendingRequest?.verificationCode, code)
    }

    func testDenyingClearsPendingRequest() {
        let store = PairedDeviceStore()
        let manager = PairingManager(deviceStore: store)

        _ = manager.createChallenge(deviceId: "d1", deviceName: "Phone", deviceType: "android")
        XCTAssertNotNil(manager.pendingRequest)

        manager.deny()
        XCTAssertNil(manager.pendingRequest)
    }

    func testApproveOnceCreatesDevice() {
        let store = PairedDeviceStore()
        let manager = PairingManager(deviceStore: store)

        let (code, _) = manager.createChallenge(deviceId: "d1", deviceName: "Phone", deviceType: "android")
        manager.approveOnce()

        XCTAssertNil(manager.pendingRequest)

        let device = store.device(withId: "d1")
        XCTAssertNotNil(device)
        XCTAssertEqual(device?.trustLevel, .once)

        let result = manager.completePairing(deviceId: "d1", verificationCode: code)
        if case .success(let token, let trust) = result {
            XCTAssertFalse(token.isEmpty)
            XCTAssertEqual(trust, .once)
        } else {
            XCTFail("Expected success, got \(result)")
        }
    }

    func testVerifySessionFailsForUnknown() {
        let store = PairedDeviceStore()
        let manager = PairingManager(deviceStore: store)
        XCTAssertFalse(manager.verifySession(deviceId: "unknown", sessionToken: "fake"))
    }
}

// MARK: - PairedDevice Model Tests

final class PairedDeviceModelTests: XCTestCase {

    func testRoundTripsJSON() throws {
        let device = PairedDevice(
            id: "abc123",
            name: "My Phone",
            deviceType: "android",
            trustLevel: .always,
            firstSeenDate: Date(timeIntervalSince1970: 1000),
            lastSeenDate: Date(timeIntervalSince1970: 2000),
            sessionToken: "token-xyz"
        )

        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(PairedDevice.self, from: data)

        XCTAssertEqual(decoded.id, device.id)
        XCTAssertEqual(decoded.name, device.name)
        XCTAssertEqual(decoded.trustLevel, .always)
        XCTAssertEqual(decoded.sessionToken, "token-xyz")
    }
}
