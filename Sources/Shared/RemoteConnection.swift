import Foundation

public enum RemoteConnectionMode: String, CaseIterable, Codable, Equatable, Sendable {
    case localNetwork
    case officialRelay
    case customRelay

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.localNetwork.rawValue:
            self = .localNetwork
        case Self.officialRelay.rawValue:
            self = .officialRelay
        case Self.customRelay.rawValue, "relay":
            self = .customRelay
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown remote connection mode: \(rawValue)"
            )
        }
    }

    public var label: String {
        switch self {
        case .localNetwork:
            "LAN"
        case .officialRelay:
            "Official"
        case .customRelay:
            "Custom"
        }
    }
}

public struct RemoteConnectionConfiguration: Equatable, Sendable {
    public let mode: RemoteConnectionMode
    public let host: String
    public let port: UInt16
    public let relayEndpoint: String
    public let relayServerId: String
    public let relayAccessToken: String?
    public let relayCommandKey: String?

    public init(host: String, port: UInt16, commandKey: String? = nil) {
        mode = .localNetwork
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        relayEndpoint = ""
        relayServerId = ""
        relayAccessToken = nil
        relayCommandKey = Self.trimmedNonEmpty(commandKey)
    }

    public init(
        mode: RemoteConnectionMode = .customRelay,
        relayEndpoint: String,
        relayServerId: String,
        relayAccessToken: String? = nil,
        relayCommandKey: String? = nil
    ) {
        self.mode = mode
        host = ""
        port = 0
        self.relayEndpoint = relayEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.relayServerId = relayServerId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.relayAccessToken = Self.trimmedNonEmpty(relayAccessToken)
        self.relayCommandKey = Self.trimmedNonEmpty(relayCommandKey)
    }

    public var displayEndpoint: String {
        switch mode {
        case .localNetwork:
            "\(host):\(port)"
        case .officialRelay, .customRelay:
            "\(relayEndpoint) / \(relayServerId)"
        }
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

public enum RemoteConnectionStatus: Equatable, Sendable {
    case idle
    case connecting
    case ready
    case failed(String)

    public var label: String {
        switch self {
        case .idle:
            "Idle"
        case .connecting:
            "Connecting"
        case .ready:
            "Connected"
        case .failed:
            "Failed"
        }
    }
}

public enum RemoteControlError: LocalizedError, Equatable {
    case invalidHost
    case invalidPort
    case invalidRelayEndpoint
    case invalidRelayServerId
    case missingRelayAccessToken
    case officialRelayCustomRequiresMatchingSignIn
    case officialRelayRequiresAppleSignIn
    case officialRelayRegistrationFailed(String)
    case disconnected
    case connectionTimedOut(host: String, port: UInt16)
    case relayConnectionTimedOut(endpoint: String, serverId: String)

    public var errorDescription: String? {
        switch self {
        case .invalidHost:
            "Enter the Mac host or IP address."
        case .invalidPort:
            "Enter a port between 1 and 65535."
        case .invalidRelayEndpoint:
            "Enter a relay endpoint such as relay.example.com:443."
        case .invalidRelayServerId:
            "Enter the Mac relay server ID."
        case .missingRelayAccessToken:
            "Sign in with Apple before using Remote Trackpad Relay."
        case .officialRelayCustomRequiresMatchingSignIn:
            "This is an official relay address. Switch to Official, or sign in with Apple again before using it in Custom."
        case .officialRelayRequiresAppleSignIn:
            "Sign in with Apple to use Remote Trackpad Relay."
        case let .officialRelayRegistrationFailed(message):
            "Remote Trackpad Relay registration failed: \(message)"
        case .disconnected:
            "Connect to the Mac host before sending commands."
        case let .connectionTimedOut(host, port):
            """
            Timed out connecting to \(host):\(port). Check that the iPhone and Mac are on the same Wi-Fi, \
            Local Network access is allowed, and the Mac host is running.
            """
        case let .relayConnectionTimedOut(endpoint, serverId):
            """
            Timed out connecting through \(endpoint) for \(serverId). Check the relay URL, TLS, and that the \
            Mac host is connected to the same relay server ID.
            """
        }
    }
}

public enum RemoteConnectionValidator {
    public static func makeConfiguration(
        host: String,
        portText: String,
        commandKey: String? = nil
    ) throws -> RemoteConnectionConfiguration {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw RemoteControlError.invalidHost
        }

        guard let parsedPort = UInt16(portText) else {
            throw RemoteControlError.invalidPort
        }

        return RemoteConnectionConfiguration(host: trimmedHost, port: parsedPort, commandKey: commandKey)
    }

    public static func makeCustomRelayConfiguration(
        endpoint: String,
        serverId: String,
        accessToken: String? = nil,
        commandKey: String? = nil
    ) throws -> RemoteConnectionConfiguration {
        let normalizedEndpoint = try RelayEndpoint.normalizedEndpoint(endpoint)
        let trimmedServerId = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServerId.isEmpty else {
            throw RemoteControlError.invalidRelayServerId
        }

        return RemoteConnectionConfiguration(
            mode: .customRelay,
            relayEndpoint: normalizedEndpoint,
            relayServerId: trimmedServerId,
            relayAccessToken: trimmedNonEmpty(accessToken),
            relayCommandKey: trimmedNonEmpty(commandKey)
        )
    }

    public static func makeOfficialRelayConfiguration(
        endpoint: String,
        serverId: String,
        accessToken: String,
        commandKey: String? = nil
    ) throws -> RemoteConnectionConfiguration {
        let normalizedEndpoint = try RelayEndpoint.normalizedEndpoint(endpoint)
        let trimmedServerId = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServerId.isEmpty else {
            throw RemoteControlError.invalidRelayServerId
        }

        let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw RemoteControlError.missingRelayAccessToken
        }

        return RemoteConnectionConfiguration(
            mode: .officialRelay,
            relayEndpoint: normalizedEndpoint,
            relayServerId: trimmedServerId,
            relayAccessToken: trimmedToken,
            relayCommandKey: trimmedNonEmpty(commandKey)
        )
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    public static func makeRelayConfiguration(
        endpoint: String,
        serverId: String
    ) throws -> RemoteConnectionConfiguration {
        try makeCustomRelayConfiguration(endpoint: endpoint, serverId: serverId)
    }
}

public enum RelayRole: String, Sendable {
    case server
    case client
}

public enum RelayEndpoint {
    /// The HTTPS endpoint a desktop host calls to renew its relay access token.
    /// Relay access tokens expire after a week and only the iOS app can mint new
    /// ones, so the host renews its own by proving it holds the account's
    /// command key.
    public static func desktopRefreshURL(endpoint: String) throws -> URL {
        let normalizedEndpoint = try normalizedEndpoint(endpoint)
        guard var components = URLComponents(string: normalizedEndpoint) else {
            throw RemoteControlError.invalidRelayEndpoint
        }

        components.scheme = components.scheme?.lowercased() == "ws" ? "http" : "https"
        components.path = "/v1/remote-trackpad/desktop/refresh"
        components.queryItems = nil

        guard let url = components.url else {
            throw RemoteControlError.invalidRelayEndpoint
        }
        return url
    }

    public static func normalizedEndpoint(_ rawEndpoint: String) throws -> String {
        let trimmedEndpoint = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEndpoint.isEmpty else {
            throw RemoteControlError.invalidRelayEndpoint
        }

        let endpointWithScheme = trimmedEndpoint.contains("://") ? trimmedEndpoint : "wss://\(trimmedEndpoint)"
        guard var components = URLComponents(string: endpointWithScheme) else {
            throw RemoteControlError.invalidRelayEndpoint
        }

        switch components.scheme?.lowercased() {
        case "wss", "ws":
            break
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            throw RemoteControlError.invalidRelayEndpoint
        }

        guard components.host?.isEmpty == false else {
            throw RemoteControlError.invalidRelayEndpoint
        }

        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let endpoint = components.url?.absoluteString else {
            throw RemoteControlError.invalidRelayEndpoint
        }
        return endpoint
    }

    public static func webSocketURL(
        endpoint: String,
        serverId: String,
        role: RelayRole,
        connectionId: String? = nil,
        accessToken _: String? = nil
    ) throws -> URL {
        let normalizedEndpoint = try normalizedEndpoint(endpoint)
        guard var components = URLComponents(string: normalizedEndpoint) else {
            throw RemoteControlError.invalidRelayEndpoint
        }

        let trimmedServerId = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServerId.isEmpty else {
            throw RemoteControlError.invalidRelayServerId
        }

        var queryItems = [
            URLQueryItem(name: "serverId", value: trimmedServerId),
            URLQueryItem(name: "role", value: role.rawValue),
            URLQueryItem(name: "v", value: "2")
        ]
        if let connectionId, !connectionId.isEmpty {
            queryItems.append(URLQueryItem(name: "connectionId", value: connectionId))
        }

        components.path = "/ws"
        components.queryItems = queryItems

        guard let url = components.url else {
            throw RemoteControlError.invalidRelayEndpoint
        }
        return url
    }

    public static func webSocketRequest(
        endpoint: String,
        serverId: String,
        role: RelayRole,
        connectionId: String? = nil,
        accessToken: String? = nil
    ) throws -> URLRequest {
        let url = try webSocketURL(
            endpoint: endpoint,
            serverId: serverId,
            role: role,
            connectionId: connectionId
        )
        var request = URLRequest(url: url)
        if let accessToken {
            let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedToken.isEmpty {
                request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }
}
