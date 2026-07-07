import Foundation

enum HostTransport: String, Equatable {
    case lan = "LAN"
    case relayControl = "Relay control"
    case relay = "Relay"
}

enum HostConnectionState: String, Equatable {
    case connecting = "Connecting"
    case connected = "Connected"
    case disconnected = "Disconnected"
    case failed = "Failed"
}

struct HostClientStatus: Equatable, Identifiable {
    let id: String
    var transport: HostTransport
    var endpoint: String
    var state: HostConnectionState
    var connectedAt: Date?
    var commandCount: Int
    var invalidFrameCount: Int
    var lastCommandAt: Date?
    var lastLatencyMillis: Int?
    var lastError: String?
}

struct HostRuntimeSnapshot: Equatable {
    var accessibilityTrusted = false
    var lanPort: UInt16?
    var lanState: HostConnectionState = .disconnected
    var lanCommandKeyConfigured = false
    var relayEndpoint: String?
    var relayServerId: String?
    var relayState: HostConnectionState = .disconnected
    var clients: [HostClientStatus] = []
    var recentLogs: [String] = []

    var activeClientCount: Int {
        clients.filter { $0.state == .connected }.count
    }
}

protocol HostStatusReporting: AnyObject {
    func updateAccessibilityTrusted(_ trusted: Bool)
    func updateLan(commandKeyConfigured: Bool)
    func lanListening(port: UInt16)
    func lanFailed(_ message: String)
    func relayConnecting(endpoint: String, serverId: String)
    func relayConnected(endpoint: String, serverId: String)
    func relayDisconnected(_ message: String)
    func clientConnected(id: String, transport: HostTransport, endpoint: String)
    func clientDisconnected(id: String, message: String)
    func commandReceived(id: String, issuedAtMillis: Int64, command: RemoteCommand)
    func invalidFrame(id: String, message: String)
    func recordLog(_ message: String)
}

final class NoOpHostStatusReporter: HostStatusReporting {
    func updateAccessibilityTrusted(_: Bool) {}
    func updateLan(commandKeyConfigured _: Bool) {}
    func lanListening(port _: UInt16) {}
    func lanFailed(_: String) {}
    func relayConnecting(endpoint _: String, serverId _: String) {}
    func relayConnected(endpoint _: String, serverId _: String) {}
    func relayDisconnected(_: String) {}
    func clientConnected(id _: String, transport _: HostTransport, endpoint _: String) {}
    func clientDisconnected(id _: String, message _: String) {}
    func commandReceived(id _: String, issuedAtMillis _: Int64, command _: RemoteCommand) {}
    func invalidFrame(id _: String, message _: String) {}
    func recordLog(_: String) {}
}

final class HostStatusStore: HostStatusReporting, @unchecked Sendable {
    typealias Observer = @Sendable (HostRuntimeSnapshot) -> Void

    private let lock = NSLock()
    private var currentSnapshot = HostRuntimeSnapshot()
    private var observers: [UUID: Observer] = [:]

    func snapshot() -> HostRuntimeSnapshot {
        lock.withLock {
            currentSnapshot
        }
    }

    func observe(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        let snapshot = lock.withLock {
            observers[id] = observer
            return currentSnapshot
        }
        observer(snapshot)
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.withLock {
            observers[id] = nil
        }
    }

    func updateAccessibilityTrusted(_ trusted: Bool) {
        update {
            $0.accessibilityTrusted = trusted
        }
    }

    func updateLan(commandKeyConfigured: Bool) {
        update {
            $0.lanCommandKeyConfigured = commandKeyConfigured
        }
    }

    func lanListening(port: UInt16) {
        updateWithLog("LAN listening on port \(port)") {
            $0.lanPort = port
            $0.lanState = .connected
        }
    }

    func lanFailed(_ message: String) {
        updateWithLog("LAN failed: \(message)") {
            $0.lanState = .failed
        }
    }

    func relayConnecting(endpoint: String, serverId: String) {
        updateWithLog("Relay connecting to \(endpoint) as \(serverId)") {
            $0.relayEndpoint = endpoint
            $0.relayServerId = serverId
            $0.relayState = .connecting
        }
    }

    func relayConnected(endpoint: String, serverId: String) {
        updateWithLog("Relay control connected to \(endpoint)") {
            $0.relayEndpoint = endpoint
            $0.relayServerId = serverId
            $0.relayState = .connected
        }
    }

    func relayDisconnected(_ message: String) {
        updateWithLog("Relay disconnected: \(message)") {
            $0.relayState = .disconnected
        }
    }

    func clientConnected(id: String, transport: HostTransport, endpoint: String) {
        updateWithLog("\(transport.rawValue) client connected: \(endpoint)") {
            $0.upsertClient(
                HostClientStatus(
                    id: id,
                    transport: transport,
                    endpoint: endpoint,
                    state: .connected,
                    connectedAt: Date(),
                    commandCount: 0,
                    invalidFrameCount: 0,
                    lastCommandAt: nil,
                    lastLatencyMillis: nil,
                    lastError: nil
                )
            )
        }
    }

    func clientDisconnected(id: String, message: String) {
        updateWithLog("Client disconnected: \(message)") {
            $0.updateClient(id: id) { client in
                client.state = .disconnected
                client.lastError = client.lastError ?? message
            }
        }
    }

    func commandReceived(id: String, issuedAtMillis: Int64, command: RemoteCommand) {
        update {
            $0.updateClient(id: id) { client in
                client.commandCount += 1
                client.lastCommandAt = Date()
                client.lastLatencyMillis = Self.latencyMillis(from: issuedAtMillis)
                client.lastError = nil
            }
            $0.appendLog("Command received: \(command.summary)")
        }
    }

    func invalidFrame(id: String, message: String) {
        updateWithLog("Invalid command frame: \(message)") {
            $0.updateClient(id: id) { client in
                client.invalidFrameCount += 1
                client.lastError = message
            }
        }
    }

    func recordLog(_ message: String) {
        updateWithLog(message) { _ in }
    }

    private func update(_ mutate: (inout HostRuntimeSnapshot) -> Void) {
        let update = lock.withLock {
            mutate(&currentSnapshot)
            return (currentSnapshot, Array(observers.values))
        }
        update.1.forEach { $0(update.0) }
    }

    private func updateWithLog(_ message: String, mutate: (inout HostRuntimeSnapshot) -> Void) {
        update {
            mutate(&$0)
            $0.appendLog(message)
        }
    }

    private static func latencyMillis(from issuedAtMillis: Int64) -> Int? {
        guard issuedAtMillis > 0 else {
            return nil
        }
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        return max(0, Int(nowMillis - issuedAtMillis))
    }
}

private extension HostRuntimeSnapshot {
    mutating func upsertClient(_ client: HostClientStatus) {
        if let index = clients.firstIndex(where: { $0.id == client.id }) {
            clients[index] = client
        } else {
            clients.append(client)
        }
    }

    mutating func updateClient(id: String, mutate: (inout HostClientStatus) -> Void) {
        guard let index = clients.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&clients[index])
    }

    mutating func appendLog(_ message: String) {
        let formatter = Self.logTimeFormatter
        recentLogs.insert("\(formatter.string(from: Date())) \(message)", at: 0)
        if recentLogs.count > 8 {
            recentLogs.removeLast(recentLogs.count - 8)
        }
    }

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private extension RemoteCommand {
    var summary: String {
        switch self {
        case .mouseMove:
            "mouse move"
        case .mouseScroll, .mouseScrollPhase:
            "scroll"
        case let .mouseButton(command):
            "\(command.button.rawValue) \(command.phase.rawValue)"
        case .text:
            "text"
        case let .key(key):
            "key \(key.rawValue)"
        case let .keyCombo(combo):
            "combo \(combo.displayTitle)"
        case let .shortcut(shortcut):
            "shortcut \(shortcut.rawValue)"
        case .ping:
            "ping"
        }
    }
}
