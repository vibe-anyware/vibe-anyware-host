import Foundation
@preconcurrency import Network

final class VibeAnywareServer: @unchecked Sendable {
    private let inputController: MacInputControlling
    private let commandKey: String?
    private let statusReporter: HostStatusReporting
    private let listener: NWListener
    private let queue = DispatchQueue(label: "VibeAnyware.HostServer", qos: .userInitiated)
    private let inputQueue = DispatchQueue(label: "VibeAnyware.HostInput", qos: .userInteractive)
    private var activeReceivers: [UUID: ConnectionReceiver] = [:]

    init(
        port: UInt16,
        commandKey: String? = nil,
        inputController: MacInputControlling = MacInputController(),
        statusReporter: HostStatusReporting = NoOpHostStatusReporter()
    ) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw RemoteControlError.invalidPort
        }

        self.inputController = inputController
        self.commandKey = commandKey?.trimmingCharacters(in: .whitespacesAndNewlines).emptyToNil
        self.statusReporter = statusReporter
        listener = try NWListener(using: NetworkRemoteEventClient.makeLowLatencyTCPParameters(), on: endpointPort)
        statusReporter.updateLan(commandKeyConfigured: self.commandKey != nil)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = self.listener.port {
                    let message = "VibeAnyware listening on port \(port.rawValue)"
                    print(message)
                    self.statusReporter.lanListening(port: port.rawValue)
                }
            case let .failed(error):
                let message = error.localizedDescription
                print("VibeAnyware failed: \(message)")
                self.statusReporter.lanFailed(message)
            case .cancelled:
                print("VibeAnyware stopped.")
                self.statusReporter.recordLog("LAN listener stopped")
            case .setup, .waiting:
                break
            @unknown default:
                print("VibeAnyware entered an unknown state.")
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        let receiverID = UUID()
        let receiverIDText = receiverID.uuidString
        let receiver = ConnectionReceiver(
            id: receiverIDText,
            connection: connection,
            inputController: inputController,
            inputQueue: inputQueue,
            commandKey: commandKey,
            statusReporter: statusReporter,
            onClose: {
                self.removeReceiver(receiverID)
            }
        )
        activeReceivers[receiverID] = receiver
        statusReporter.clientConnected(
            id: receiverIDText,
            transport: .lan,
            endpoint: String(describing: connection.endpoint)
        )
        connection.start(queue: queue)
        receiver.receiveNext()
    }

    private func removeReceiver(_ receiverID: UUID) {
        queue.async {
            self.activeReceivers[receiverID] = nil
        }
    }
}

private final class ConnectionReceiver: @unchecked Sendable {
    private let id: String
    private let connection: NWConnection
    private let inputController: MacInputControlling
    private let inputQueue: DispatchQueue
    private let commandKey: String?
    private let statusReporter: HostStatusReporting
    private let onClose: @Sendable () -> Void
    private var frameBuffer = LineFrameBuffer()

    init(
        id: String,
        connection: NWConnection,
        inputController: MacInputControlling,
        inputQueue: DispatchQueue,
        commandKey: String?,
        statusReporter: HostStatusReporting,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.connection = connection
        self.inputController = inputController
        self.inputQueue = inputQueue
        self.commandKey = commandKey
        self.statusReporter = statusReporter
        self.onClose = onClose
    }

    func receiveNext() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }

            if let data, !data.isEmpty {
                self.handle(data)
            }

            if let error {
                let message = error.localizedDescription
                print("Connection receive failed: \(message)")
                self.statusReporter.clientDisconnected(id: self.id, message: message)
                self.close()
                return
            }

            if isComplete {
                print("VibeAnyware client disconnected.")
                self.statusReporter.clientDisconnected(id: self.id, message: "LAN client disconnected")
                self.close()
                return
            }

            self.receiveNext()
        }
    }

    private func handle(_ data: Data) {
        for frame in frameBuffer.append(data) {
            do {
                let envelope = try RemoteCommandCodec.decodeLine(
                    frame,
                    accessToken: commandKey,
                    requiresSecure: commandKey != nil
                )
                statusReporter.commandReceived(
                    id: id,
                    issuedAtMillis: envelope.issuedAtMillis,
                    command: envelope.command
                )
                inputQueue.async {
                    self.inputController.handle(envelope.command)
                }
            } catch {
                let message = error.localizedDescription
                print("Invalid command frame: \(message)")
                statusReporter.invalidFrame(id: id, message: message)
            }
        }
    }

    private func close() {
        connection.cancel()
        onClose()
    }
}

private extension String {
    var emptyToNil: String? {
        isEmpty ? nil : self
    }
}
