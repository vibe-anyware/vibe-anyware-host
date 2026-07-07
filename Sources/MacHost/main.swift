import AppKit
import Foundation
import Darwin

let defaultPort: UInt16 = 45731
private var retainedServer: VibeAnywareServer?
private var retainedRelayClient: VibeAnywareRelayHostClient?
private var retainedMenuBarController: MenuBarStatusController?
private var retainedAccessibilityTimer: Timer?

setbuf(stdout, nil)
setbuf(stderr, nil)

do {
    let launchConfiguration = try HostLaunchConfiguration(
        arguments: CommandLine.arguments,
        environment: ProcessInfo.processInfo.environment
    )
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let statusStore = HostStatusStore()
    statusStore.updateAccessibilityTrusted(MacInputController.isAccessibilityTrusted())
    statusStore.updateLan(commandKeyConfigured: launchConfiguration.lanCommandKey != nil)
    let syntheticCursor = SyntheticCursorController()
    retainedMenuBarController = MenuBarStatusController(
        statusStore: statusStore,
        syntheticCursor: syntheticCursor
    )
    retainedAccessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
        statusStore.updateAccessibilityTrusted(MacInputController.isAccessibilityTrusted())
    }

    if !statusStore.snapshot().accessibilityTrusted {
        print("Accessibility permission is required for mouse and keyboard control.")
    }

    let inputController = MacInputController()
    inputController.onPointerMoved = { point in
        syntheticCursor.pointerMoved(to: point)
    }
    let server = try VibeAnywareServer(
        port: launchConfiguration.port,
        commandKey: launchConfiguration.lanCommandKey,
        inputController: inputController,
        statusReporter: statusStore
    )
    retainedServer = server
    server.start()
    if let relayConfiguration = launchConfiguration.relay {
        let client = VibeAnywareRelayHostClient(
            configuration: relayConfiguration,
            inputController: inputController,
            statusReporter: statusStore
        )
        retainedRelayClient = client
        client.start()
        print("VibeAnyware relay enabled for server ID \(relayConfiguration.serverId)")
    }
    print("VibeAnyware is running in the macOS menu bar.")
    app.run()
} catch {
    fputs("VibeAnyware failed to start: \(error.localizedDescription)\n", stderr)
    exit(1)
}

private struct HostLaunchConfiguration {
    let port: UInt16
    let lanCommandKey: String?
    let relay: RelayHostConfiguration?

    init(arguments: [String], environment: [String: String]) throws {
        var values = HostLaunchValues(environment: environment)
        var index = arguments.index(after: arguments.startIndex)

        while index < arguments.endIndex {
            try values.apply(argument: arguments[index], arguments: arguments, index: &index)
            index = arguments.index(after: index)
        }

        try values.applyOfficialRelaySetupKeyIfNeeded()
        port = values.port
        lanCommandKey = values.lanCommandKey?.trimmingCharacters(in: .whitespacesAndNewlines).emptyToNil

        if let relayEndpoint = values.relayEndpoint, let relayServerId = values.relayServerId {
            relay = try RelayHostConfiguration(
                endpoint: relayEndpoint,
                serverId: relayServerId,
                accessToken: values.relayAccessToken,
                commandKey: values.relayCommandKey
            )
        } else if values.relayEndpoint != nil || values.relayServerId != nil {
            throw RemoteControlError.invalidRelayEndpoint
        } else {
            relay = nil
        }
    }
}

private struct HostLaunchValues {
    var port = defaultPort
    var relayEndpoint: String?
    var relayServerId: String?
    var relayAccessToken: String?
    var relayCommandKey: String?
    var officialRelaySetupKey: String?
    var lanCommandKey: String?

    init(environment: [String: String]) {
        relayEndpoint = environment["VIBE_ANYWARE_RELAY_ENDPOINT"] ?? environment["VIBE_ANYWARE_RELAY_URL"]
        relayServerId = environment["VIBE_ANYWARE_RELAY_SERVER_ID"]
        relayAccessToken = environment["VIBE_ANYWARE_RELAY_ACCESS_TOKEN"]
        relayCommandKey = environment["VIBE_ANYWARE_RELAY_COMMAND_KEY"]
        officialRelaySetupKey = environment["VIBE_ANYWARE_OFFICIAL_RELAY_SETUP_KEY"]
        lanCommandKey = environment["VIBE_ANYWARE_LAN_COMMAND_KEY"]
    }

    mutating func apply(argument: String, arguments: [String], index: inout Array<String>.Index) throws {
        switch argument {
        case "--relay":
            relayEndpoint = try nextValue(arguments: arguments, index: &index, error: .invalidRelayEndpoint)
        case "--server-id":
            relayServerId = try nextValue(arguments: arguments, index: &index, error: .invalidRelayServerId)
        case "--relay-access-token":
            relayAccessToken = try nextValue(arguments: arguments, index: &index, error: .missingRelayAccessToken)
        case "--relay-command-key":
            relayCommandKey = try nextValue(arguments: arguments, index: &index, error: .missingRelayAccessToken)
        case "--official-relay-setup-key":
            officialRelaySetupKey = try nextValue(arguments: arguments, index: &index, error: .missingRelayAccessToken)
        case "--lan-command-key":
            lanCommandKey = try nextValue(arguments: arguments, index: &index, error: .missingRelayAccessToken)
        default:
            guard let requestedPort = UInt16(argument) else {
                throw RemoteControlError.invalidPort
            }
            port = requestedPort
        }
    }

    private func nextValue(
        arguments: [String],
        index: inout Array<String>.Index,
        error: RemoteControlError
    ) throws -> String {
        index = arguments.index(after: index)
        guard index < arguments.endIndex else {
            throw error
        }
        return arguments[index]
    }

    mutating func applyOfficialRelaySetupKeyIfNeeded() throws {
        guard let rawSetupKey = officialRelaySetupKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSetupKey.isEmpty else {
            return
        }

        let setupKey = try OfficialRelaySetupKey.decode(rawSetupKey)
        relayEndpoint = relayEndpoint ?? setupKey.endpoint
        relayServerId = relayServerId ?? setupKey.serverId
        relayAccessToken = relayAccessToken ?? setupKey.accessToken
        relayCommandKey = relayCommandKey ?? setupKey.commandKey
    }
}

private extension String {
    var emptyToNil: String? {
        isEmpty ? nil : self
    }
}
