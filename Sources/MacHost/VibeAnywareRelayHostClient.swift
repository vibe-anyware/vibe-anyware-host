import CryptoKit
import Foundation

struct RelayHostConfiguration: Equatable, Sendable {
    let endpoint: String
    let serverId: String
    let accessToken: String?
    let commandKey: String?

    init(endpoint: String, serverId: String, accessToken: String? = nil, commandKey: String? = nil) throws {
        self.endpoint = try RelayEndpoint.normalizedEndpoint(endpoint)
        let trimmedServerId = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServerId.isEmpty else {
            throw RemoteControlError.invalidRelayServerId
        }
        self.serverId = trimmedServerId
        let trimmedToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessToken = trimmedToken?.isEmpty == false ? trimmedToken : nil
        let trimmedCommandKey = commandKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.commandKey = trimmedCommandKey?.isEmpty == false ? trimmedCommandKey : nil
    }
}

final class VibeAnywareRelayHostClient: @unchecked Sendable {
    private let configuration: RelayHostConfiguration
    private let inputController: MacInputControlling
    private let statusReporter: HostStatusReporting
    private let session: URLSession
    private let queue = DispatchQueue(label: "VibeAnyware.RelayHost", qos: .userInitiated)
    private let inputQueue = DispatchQueue(label: "VibeAnyware.RelayInput", qos: .userInteractive)
    private var controlTask: URLSessionWebSocketTask?
    private var dataTasks: [String: URLSessionWebSocketTask] = [:]
    private var frameBuffers: [String: LineFrameBuffer] = [:]

    /// The token we actually connect with. It starts out as the one baked into
    /// the setup key, but relay access tokens expire after a week and only the
    /// iOS app can call /register, so we mint our own replacements instead of
    /// going dark. Rotating it is safe: command frames are decrypted with
    /// `commandKey`, never with this.
    private var activeAccessToken: String?
    private var accessTokenExpiresAt: Date?
    /// Set after any control-socket failure. A rejected handshake — the shape an
    /// expired token takes — reaches us only as a generic "bad server response",
    /// so we renew the token before trying again rather than guessing.
    private var needsTokenRefresh = false
    private var reconnectDelay: TimeInterval = VibeAnywareRelayHostClient.minReconnectDelay
    private var refreshWorkItem: DispatchWorkItem?

    init(
        configuration: RelayHostConfiguration,
        inputController: MacInputControlling = MacInputController(),
        statusReporter: HostStatusReporting = NoOpHostStatusReporter(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.inputController = inputController
        self.statusReporter = statusReporter
        self.session = session
        self.activeAccessToken = configuration.accessToken
    }

    static let keepaliveIntervalSeconds: TimeInterval = 30
    static let minReconnectDelay: TimeInterval = 2
    static let maxReconnectDelay: TimeInterval = 30

    func start() {
        queue.async {
            self.connectControl()
            self.scheduleKeepalivePings()
        }
    }

    /// Renew the access token when there's reason to doubt ours, then open the
    /// control socket. We can only renew when the setup key gave us a command
    /// key to prove ownership with; otherwise we connect with what we have.
    private func connectControl() {
        guard configuration.commandKey != nil, needsTokenRefresh || isAccessTokenStale else {
            openControlSocket()
            return
        }

        refreshAccessToken { [weak self] _ in
            guard let self else {
                return
            }
            // Open regardless: if the refresh failed we still want the socket to
            // try (and surface) the real error rather than sit idle.
            self.openControlSocket()
        }
    }

    /// A token from the setup key carries no expiry we can read, and it may well
    /// be weeks old, so treat it as stale and mint a fresh one on startup.
    private var isAccessTokenStale: Bool {
        guard activeAccessToken != nil, let expiry = accessTokenExpiresAt else {
            return true
        }
        return expiry.timeIntervalSinceNow < 60
    }

    private func refreshAccessToken(completion: @escaping (Bool) -> Void) {
        guard let commandKey = configuration.commandKey,
              let url = try? RelayEndpoint.desktopRefreshURL(endpoint: configuration.endpoint) else {
            completion(false)
            return
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let payload = DesktopRefreshRequest(
            serverId: configuration.serverId,
            timestamp: timestamp,
            proof: Self.desktopRefreshProof(
                commandKey: commandKey,
                serverId: configuration.serverId,
                timestamp: timestamp
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(payload)

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                completion(false)
                return
            }

            self.queue.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200,
                      let data,
                      let refreshed = try? JSONDecoder().decode(DesktopRefreshResponse.self, from: data) else {
                    let reason = Self.refreshFailureReason(status: status, error: error)
                    print("VibeAnyware relay token refresh failed: \(reason)")
                    self.statusReporter.recordLog("Relay token refresh failed: \(reason)")
                    completion(false)
                    return
                }

                self.activeAccessToken = refreshed.accessToken
                self.accessTokenExpiresAt = Date(timeIntervalSince1970: TimeInterval(refreshed.expiresAt))
                self.needsTokenRefresh = false
                print("VibeAnyware relay token refreshed")
                self.scheduleProactiveRefresh()
                completion(true)
            }
        }.resume()
    }

    private static func refreshFailureReason(status: Int, error: Error?) -> String {
        if let error {
            return error.localizedDescription
        }
        if status == 401 {
            return "relay rejected this Mac; regenerate the setup key in the app"
        }
        return "relay token refresh returned HTTP \(status)"
    }

    /// Renew at half the remaining lifetime, so a long-lived host never hands a
    /// dead token to the socket in the first place.
    private func scheduleProactiveRefresh() {
        refreshWorkItem?.cancel()
        guard let expiry = accessTokenExpiresAt else {
            return
        }

        let remaining = expiry.timeIntervalSinceNow
        guard remaining > 0 else {
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.refreshAccessToken { _ in }
        }
        refreshWorkItem = work
        queue.asyncAfter(deadline: .now() + max(60, remaining / 2), execute: work)
    }

    /// Mirrors the gateway's `desktopRefreshProof`: HMAC-SHA256 over
    /// "desktop-refresh:<serverId>:<timestamp>", keyed by the command key, so the
    /// key itself never goes over the wire.
    private static func desktopRefreshProof(
        commandKey: String,
        serverId: String,
        timestamp: Int
    ) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data("desktop-refresh:\(serverId):\(timestamp)".utf8),
            using: SymmetricKey(data: Data(commandKey.utf8))
        )
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// Periodic WebSocket pings on the control and data sockets so idle
    /// timeouts along the proxy chain never reap a healthy connection, and
    /// half-open sockets surface as receive failures quickly.
    private func scheduleKeepalivePings() {
        queue.asyncAfter(deadline: .now() + Self.keepaliveIntervalSeconds) { [weak self] in
            guard let self else {
                return
            }
            controlTask?.sendPing { _ in }
            for task in dataTasks.values {
                task.sendPing { _ in }
            }
            scheduleKeepalivePings()
        }
    }

    private func openControlSocket() {
        do {
            statusReporter.relayConnecting(endpoint: configuration.endpoint, serverId: configuration.serverId)
            let request = try RelayEndpoint.webSocketRequest(
                endpoint: configuration.endpoint,
                serverId: configuration.serverId,
                role: .server,
                accessToken: activeAccessToken
            )
            let task = session.webSocketTask(with: request)
            controlTask = task
            task.resume()

            // `resume()` only kicks off the handshake. A rejected upgrade — what
            // an expired token looks like — surfaces afterwards, so wait for a
            // ping to come back before claiming we're connected. Reporting
            // "connected" here was why an unauthorized host looked healthy while
            // it reconnected in a loop forever.
            task.sendPing { [weak self] error in
                guard let self else {
                    return
                }
                self.queue.async {
                    guard self.controlTask === task else {
                        return
                    }
                    if let error {
                        self.handleControlFailure(error, task: task)
                        return
                    }
                    self.reconnectDelay = Self.minReconnectDelay
                    print("VibeAnyware relay control connected to \(self.configuration.endpoint)")
                    self.statusReporter.relayConnected(
                        endpoint: self.configuration.endpoint,
                        serverId: self.configuration.serverId
                    )
                }
            }

            receiveControlMessage(on: task)
        } catch {
            handleControlFailure(error, task: nil)
        }
    }

    private func handleControlFailure(_ error: Error, task: URLSessionWebSocketTask?) {
        if let task, controlTask !== task {
            return
        }

        let message = error.localizedDescription
        print("VibeAnyware relay control disconnected: \(message)")
        statusReporter.relayDisconnected(message)
        controlTask = nil
        needsTokenRefresh = true
        scheduleControlReconnect()
    }

    private func receiveControlMessage(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else {
                return
            }
            queue.async {
                guard self.controlTask === task else {
                    return
                }

                switch result {
                case let .success(message):
                    self.handleControlMessage(message)
                    self.receiveControlMessage(on: task)
                case let .failure(error):
                    self.handleControlFailure(error, task: task)
                }
            }
        }
    }

    private func handleControlMessage(_ message: URLSessionWebSocketTask.Message) {
        guard let data = message.dataValue else {
            return
        }

        do {
            let controlMessage = try JSONDecoder().decode(RelayControlMessage.self, from: data)
            switch controlMessage.type {
            case "connected":
                if let connectionId = controlMessage.connectionId {
                    openDataSocket(connectionId: connectionId)
                }
            case "sync":
                for connectionId in controlMessage.connectionIds ?? [] {
                    openDataSocket(connectionId: connectionId)
                }
            default:
                break
            }
        } catch {
            let message = error.localizedDescription
            print("Invalid relay control message: \(message)")
            statusReporter.recordLog("Invalid relay control message: \(message)")
        }
    }

    private func openDataSocket(connectionId: String) {
        guard dataTasks[connectionId] == nil else {
            return
        }

        do {
            let request = try RelayEndpoint.webSocketRequest(
                endpoint: configuration.endpoint,
                serverId: configuration.serverId,
                role: .server,
                connectionId: connectionId,
                accessToken: activeAccessToken
            )
            let task = session.webSocketTask(with: request)
            dataTasks[connectionId] = task
            frameBuffers[connectionId] = LineFrameBuffer()
            task.resume()
            print("VibeAnyware relay data connected: \(connectionId)")
            statusReporter.clientConnected(
                id: connectionId,
                transport: .relay,
                endpoint: connectionId
            )
            receiveDataMessage(connectionId: connectionId, task: task)
        } catch {
            let message = error.localizedDescription
            print("VibeAnyware relay data failed: \(message)")
            statusReporter.recordLog("Relay data failed: \(message)")
        }
    }

    private func receiveDataMessage(connectionId: String, task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else {
                return
            }
            queue.async {
                guard self.dataTasks[connectionId] === task else {
                    return
                }

                switch result {
                case let .success(message):
                    if let data = message.dataValue {
                        self.handleData(data, connectionId: connectionId)
                    }
                    self.receiveDataMessage(connectionId: connectionId, task: task)
                case let .failure(error):
                    let message = error.localizedDescription
                    print("VibeAnyware relay data disconnected: \(message)")
                    self.statusReporter.clientDisconnected(id: connectionId, message: message)
                    self.dataTasks[connectionId] = nil
                    self.frameBuffers[connectionId] = nil
                }
            }
        }
    }

    private func handleData(_ data: Data, connectionId: String) {
        var buffer = frameBuffers[connectionId] ?? LineFrameBuffer()
        let frames = buffer.append(data)
        frameBuffers[connectionId] = buffer

        for frame in frames {
            do {
                let envelope = try RemoteCommandCodec.decodeLine(
                    frame,
                    accessToken: configuration.commandKey ?? configuration.accessToken,
                    requiresSecure: configuration.commandKey != nil || configuration.accessToken != nil
                )
                statusReporter.commandReceived(
                    id: connectionId,
                    issuedAtMillis: envelope.issuedAtMillis,
                    command: envelope.command
                )
                inputQueue.async {
                    self.inputController.handle(envelope.command)
                }
            } catch {
                let message = error.localizedDescription
                print("Invalid relay command frame: \(message)")
                statusReporter.invalidFrame(id: connectionId, message: message)
            }
        }
    }

    /// Back off on repeated failures. A host whose token the relay refuses used
    /// to retry every two seconds forever, filling the log with thousands of
    /// identical lines.
    private func scheduleControlReconnect() {
        let delay = reconnectDelay
        reconnectDelay = min(Self.maxReconnectDelay, reconnectDelay * 2)

        queue.asyncAfter(deadline: .now() + delay) {
            guard self.controlTask == nil else {
                return
            }
            self.connectControl()
        }
    }
}

private struct RelayControlMessage: Decodable {
    let type: String
    let connectionId: String?
    let connectionIds: [String]?
}

private struct DesktopRefreshRequest: Encodable {
    let serverId: String
    let timestamp: Int
    let proof: String
}

private struct DesktopRefreshResponse: Decodable {
    let accessToken: String
    let expiresAt: Int
}

private extension URLSessionWebSocketTask.Message {
    var dataValue: Data? {
        switch self {
        case let .data(data):
            data
        case let .string(text):
            Data(text.utf8)
        @unknown default:
            nil
        }
    }
}
