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
    }

    static let keepaliveIntervalSeconds: TimeInterval = 30

    func start() {
        queue.async {
            self.openControlSocket()
            self.scheduleKeepalivePings()
        }
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
                accessToken: configuration.accessToken
            )
            let task = session.webSocketTask(with: request)
            controlTask = task
            task.resume()
            print("VibeAnyware relay control connected to \(configuration.endpoint)")
            statusReporter.relayConnected(endpoint: configuration.endpoint, serverId: configuration.serverId)
            receiveControlMessage(on: task)
        } catch {
            let message = error.localizedDescription
            print("VibeAnyware relay control failed: \(message)")
            statusReporter.relayDisconnected(message)
            scheduleControlReconnect()
        }
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
                    let message = error.localizedDescription
                    print("VibeAnyware relay control disconnected: \(message)")
                    self.statusReporter.relayDisconnected(message)
                    self.controlTask = nil
                    self.scheduleControlReconnect()
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
                accessToken: configuration.accessToken
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

    private func scheduleControlReconnect() {
        queue.asyncAfter(deadline: .now() + 2.0) {
            guard self.controlTask == nil else {
                return
            }
            self.openControlSocket()
        }
    }
}

private struct RelayControlMessage: Decodable {
    let type: String
    let connectionId: String?
    let connectionIds: [String]?
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
