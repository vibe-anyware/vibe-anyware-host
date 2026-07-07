import Foundation
@preconcurrency import Network

public protocol RemoteEventClient: AnyObject, Sendable {
    var onStateChange: (@Sendable (RemoteConnectionStatus) -> Void)? { get set }

    func connect(configuration: RemoteConnectionConfiguration)
    func disconnect()
    func send(_ command: RemoteCommand) async throws
}

protocol RemoteNetworkConnection: AnyObject, Sendable {
    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)? { get set }

    func start(queue: DispatchQueue)
    func cancel()
    func send(
        content: Data?,
        contentContext: NWConnection.ContentContext,
        isComplete: Bool,
        completion: NWConnection.SendCompletion
    )
}

extension NWConnection: RemoteNetworkConnection {}

public final class NetworkRemoteEventClient: RemoteEventClient, @unchecked Sendable {
    public var onStateChange: (@Sendable (RemoteConnectionStatus) -> Void)?

    private let queue = DispatchQueue(label: "VibeAnyware.NetworkClient", qos: .userInitiated)
    private let connectTimeout: TimeInterval
    private let makeConnection: @Sendable (RemoteConnectionConfiguration) throws -> any RemoteNetworkConnection
    private let makeRelayConnection: @Sendable (RemoteConnectionConfiguration) throws -> any RemoteNetworkConnection
    private var connection: (any RemoteNetworkConnection)?
    private var connectionGeneration = 0
    private var activeConnectionConfiguration: RemoteConnectionConfiguration?
    private var isConnectionReady = false
    private var sequence = 0

    public convenience init(connectTimeout: TimeInterval = 6.0) {
        self.init(
            connectTimeout: connectTimeout,
            makeConnection: Self.makeNWConnection(configuration:),
            makeRelayConnection: Self.makeRelayWebSocketConnection(configuration:)
        )
    }

    init(
        connectTimeout: TimeInterval,
        makeConnection: @escaping @Sendable (RemoteConnectionConfiguration) throws -> any RemoteNetworkConnection,
        makeRelayConnection: @escaping @Sendable (RemoteConnectionConfiguration) throws -> any RemoteNetworkConnection =
            NetworkRemoteEventClient.makeRelayWebSocketConnection(configuration:)
    ) {
        self.connectTimeout = connectTimeout
        self.makeConnection = makeConnection
        self.makeRelayConnection = makeRelayConnection
    }

    public func connect(configuration: RemoteConnectionConfiguration) {
        disconnect(notify: false)
        connectionGeneration += 1
        let generation = connectionGeneration
        activeConnectionConfiguration = configuration
        isConnectionReady = false
        onStateChange?(.connecting)

        let connection: any RemoteNetworkConnection
        do {
            switch configuration.mode {
            case .localNetwork:
                connection = try makeConnection(configuration)
            case .officialRelay, .customRelay:
                connection = try makeRelayConnection(configuration)
            }
        } catch {
            onStateChange?(.failed(error.localizedDescription))
            activeConnectionConfiguration = nil
            return
        }
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state, generation: generation)
        }
        connection.start(queue: queue)
        scheduleTimeout(for: generation, configuration: configuration)
    }

    public func disconnect() {
        disconnect(notify: true)
    }

    public func send(_ command: RemoteCommand) async throws {
        guard let connection else {
            throw RemoteControlError.disconnected
        }

        sequence += 1
        let envelope = RemoteCommandEnvelope(
            sequence: sequence,
            issuedAtMillis: Self.nowMillis(),
            command: command
        )
        let data = try RemoteCommandCodec.encodeWireFrame(
            envelope,
            accessToken: activeConnectionConfiguration?.relayCommandKey
                ?? activeConnectionConfiguration?.relayAccessToken
        )
        connection.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    private func disconnect(notify: Bool) {
        connectionGeneration += 1
        connection?.cancel()
        connection = nil
        activeConnectionConfiguration = nil
        isConnectionReady = false
        if notify {
            onStateChange?(.idle)
        }
    }

    private func handle(_ state: NWConnection.State, generation: Int) {
        guard generation == connectionGeneration else {
            return
        }

        switch state {
        case .setup, .preparing:
            onStateChange?(.connecting)
        case .ready:
            isConnectionReady = true
            onStateChange?(.ready)
        case let .failed(error):
            onStateChange?(.failed(error.localizedDescription))
            disconnect(notify: false)
        case .cancelled:
            onStateChange?(.idle)
        case let .waiting(error):
            onStateChange?(.failed(error.localizedDescription))
        @unknown default:
            onStateChange?(.failed("Unknown connection state."))
        }
    }

    private func scheduleTimeout(for generation: Int, configuration: RemoteConnectionConfiguration) {
        queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
            self?.failIfStillConnecting(generation: generation, configuration: configuration)
        }
    }

    private func failIfStillConnecting(
        generation: Int,
        configuration: RemoteConnectionConfiguration
    ) {
        guard generation == connectionGeneration, !isConnectionReady else {
            return
        }

        onStateChange?(
            .failed(
                timeoutError(for: configuration).localizedDescription
            )
        )
        disconnect(notify: false)
    }

    private func timeoutError(for configuration: RemoteConnectionConfiguration) -> RemoteControlError {
        switch configuration.mode {
        case .localNetwork:
            .connectionTimedOut(host: configuration.host, port: configuration.port)
        case .officialRelay, .customRelay:
            .relayConnectionTimedOut(
                endpoint: configuration.relayEndpoint,
                serverId: configuration.relayServerId
            )
        }
    }

    private static func makeNWConnection(
        configuration: RemoteConnectionConfiguration
    ) throws -> any RemoteNetworkConnection {
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw RemoteControlError.invalidPort
        }

        return NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: port,
            using: makeLowLatencyTCPParameters()
        )
    }

    private static func makeRelayWebSocketConnection(
        configuration: RemoteConnectionConfiguration
    ) throws -> any RemoteNetworkConnection {
        let request = try RelayEndpoint.webSocketRequest(
            endpoint: configuration.relayEndpoint,
            serverId: configuration.relayServerId,
            role: .client,
            accessToken: configuration.relayAccessToken
        )
        return RelayWebSocketConnection(request: request)
    }

    static func makeLowLatencyTCPParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        return NWParameters(tls: nil, tcp: tcpOptions)
    }

    private static func nowMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}

private final class RelayWebSocketConnection: RemoteNetworkConnection, @unchecked Sendable {
    static let keepaliveIntervalSeconds: TimeInterval = 30

    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?

    private let request: URLRequest
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()

    init(request: URLRequest, session: URLSession = .shared) {
        self.request = request
        self.session = session
    }

    func start(queue: DispatchQueue) {
        let task = session.webSocketTask(with: request)
        lock.withLock {
            self.task = task
        }
        task.resume()
        task.sendPing { [weak self] error in
            guard let self else {
                return
            }
            queue.async {
                if let error {
                    self.stateUpdateHandler?(.failed(.posix(Self.posixCode(for: error))))
                } else {
                    self.stateUpdateHandler?(.ready)
                    self.scheduleKeepalivePing(on: queue)
                }
            }
        }
    }

    /// Periodic pings keep proxy idle timeouts from reaping the socket and
    /// detect half-open connections, so a dead relay session reports failed
    /// (and triggers auto-reconnect) instead of silently eating commands.
    private func scheduleKeepalivePing(on queue: DispatchQueue) {
        queue.asyncAfter(deadline: .now() + Self.keepaliveIntervalSeconds) { [weak self] in
            guard let self else {
                return
            }
            let task: URLSessionWebSocketTask? = lock.withLock {
                self.task
            }
            guard let task else {
                return
            }
            task.sendPing { [weak self] error in
                guard let self else {
                    return
                }
                queue.async {
                    if let error {
                        self.stateUpdateHandler?(.failed(.posix(Self.posixCode(for: error))))
                    } else {
                        self.scheduleKeepalivePing(on: queue)
                    }
                }
            }
        }
    }

    func cancel() {
        lock.withLock {
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
        }
        stateUpdateHandler?(.cancelled)
    }

    func send(
        content: Data?,
        contentContext _: NWConnection.ContentContext,
        isComplete _: Bool,
        completion: NWConnection.SendCompletion
    ) {
        guard let content else {
            callCompletion(completion, error: nil)
            return
        }

        let task: URLSessionWebSocketTask? = lock.withLock {
            self.task
        }
        guard let task else {
            callCompletion(completion, error: .posix(.ENOTCONN))
            stateUpdateHandler?(.failed(.posix(.ENOTCONN)))
            return
        }

        task.send(URLSessionWebSocketTask.Message.data(content)) { [weak self] (error: (any Error)?) in
            if let error {
                let nwError = NWError.posix(Self.posixCode(for: error))
                self?.callCompletion(completion, error: nwError)
                self?.stateUpdateHandler?(.failed(nwError))
            } else {
                self?.callCompletion(completion, error: nil)
            }
        }
    }

    private func callCompletion(_ completion: NWConnection.SendCompletion, error: NWError?) {
        switch completion {
        case let .contentProcessed(handler):
            handler(error)
        case .idempotent:
            break
        @unknown default:
            break
        }
    }

    private static func posixCode(for error: Error) -> POSIXErrorCode {
        let code = (error as NSError).code
        return POSIXErrorCode(rawValue: Int32(code)) ?? .ECONNABORTED
    }
}
