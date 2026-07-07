import XCTest

final class HostStatusStoreTests: XCTestCase {
    func test_storeTracksLanClientCommandsAndInvalidFrames() {
        let store = HostStatusStore()
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000) - 25

        store.updateAccessibilityTrusted(true)
        store.updateLan(commandKeyConfigured: true)
        store.lanListening(port: 45731)
        store.clientConnected(id: "phone-1", transport: .lan, endpoint: "192.168.1.23")
        store.commandReceived(
            id: "phone-1",
            issuedAtMillis: issuedAtMillis,
            command: .mouseMove(PointerDelta(dx: 2, dy: 3))
        )
        store.invalidFrame(id: "phone-1", message: "wrong key")
        store.clientDisconnected(id: "phone-1", message: "LAN client disconnected")

        let snapshot = store.snapshot()
        XCTAssertTrue(snapshot.accessibilityTrusted)
        XCTAssertTrue(snapshot.lanCommandKeyConfigured)
        XCTAssertEqual(snapshot.lanPort, 45731)
        XCTAssertEqual(snapshot.activeClientCount, 0)
        XCTAssertEqual(snapshot.clients.first?.commandCount, 1)
        XCTAssertEqual(snapshot.clients.first?.invalidFrameCount, 1)
        XCTAssertEqual(snapshot.clients.first?.lastError, "wrong key")
        XCTAssertGreaterThanOrEqual(snapshot.clients.first?.lastLatencyMillis ?? -1, 0)
        XCTAssertTrue(snapshot.recentLogs.contains { $0.contains("Invalid command frame") })
    }

    func test_storeTracksRelayControlState() {
        let store = HostStatusStore()

        store.relayConnecting(endpoint: "wss://relay.example.com", serverId: "rt-test")
        store.relayConnected(endpoint: "wss://relay.example.com", serverId: "rt-test")
        store.clientConnected(id: "relay-client", transport: .relay, endpoint: "connection-1")
        store.clientDisconnected(id: "relay-client", message: "closed")

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.relayEndpoint, "wss://relay.example.com")
        XCTAssertEqual(snapshot.relayServerId, "rt-test")
        XCTAssertEqual(snapshot.relayState, .connected)
        XCTAssertEqual(snapshot.activeClientCount, 0)
        XCTAssertEqual(snapshot.clients.first?.state, .disconnected)
        XCTAssertEqual(snapshot.clients.first?.lastError, "closed")
    }
}
