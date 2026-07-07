import AppKit
import Foundation

@MainActor
final class MenuBarStatusController: NSObject {
    private let statusStore: HostStatusStore
    private let syntheticCursor: SyntheticCursorController
    private let statusItem: NSStatusItem
    private let statusIcon: NSImage?
    private lazy var setupWindowController = MacHostSetupWindowController(statusStore: statusStore)
    private var observerID: UUID?
    private var latestSnapshot = HostRuntimeSnapshot()

    init(statusStore: HostStatusStore, syntheticCursor: SyntheticCursorController) {
        self.statusStore = statusStore
        self.syntheticCursor = syntheticCursor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusIcon = Self.loadStatusIcon()
        super.init()

        statusItem.button?.image = statusIcon
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "VibeAnyware"
        observerID = statusStore.observe { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.render(snapshot)
            }
        }
    }

    deinit {
        if let observerID {
            statusStore.removeObserver(observerID)
        }
    }

    private func render(_ snapshot: HostRuntimeSnapshot) {
        latestSnapshot = snapshot
        let activeCount = snapshot.activeClientCount
        statusItem.button?.image = statusIcon
        statusItem.button?.imagePosition = activeCount > 0 ? .imageLeft : .imageOnly
        statusItem.button?.title = activeCount > 0 ? "\(activeCount)" : ""
        statusItem.button?.contentTintColor = nil
        statusItem.menu = buildMenu(snapshot)
    }

    private func buildMenu(_ snapshot: HostRuntimeSnapshot) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(header("VibeAnyware"))
        menu.addItem(actionItem("Open Setup Guide...", #selector(showSetupGuide)))
        menu.addItem(actionItem("Open Accessibility Settings", #selector(openAccessibilitySettings)))
        menu.addItem(.separator())
        let cursorItem = actionItem(
            "Show pointer for screen mirroring",
            #selector(toggleSyntheticCursor)
        )
        cursorItem.state = syntheticCursor.isEnabled ? .on : .off
        cursorItem.toolTip = "Draw an on-screen pointer so remote-desktop / screen-mirroring apps (e.g. UU远程) can show it."
        menu.addItem(cursorItem)
        menu.addItem(.separator())
        menu.addItem(statusActionItem("Accessibility", snapshot.accessibilityTrusted ? "Granted" : "Missing"))
        menu.addItem(statusActionItem("LAN", lanStatus(snapshot)))
        menu.addItem(statusActionItem("LAN key", snapshot.lanCommandKeyConfigured ? "Configured" : "Missing"))
        menu.addItem(statusActionItem("Relay", relayStatus(snapshot)))
        menu.addItem(statusActionItem("Mobile clients", clientSummary(snapshot)))

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit VibeAnyware", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func lanStatus(_ snapshot: HostRuntimeSnapshot) -> String {
        if let port = snapshot.lanPort {
            return "\(snapshot.lanState.rawValue) :\(port)"
        }
        return snapshot.lanState.rawValue
    }

    private func relayStatus(_ snapshot: HostRuntimeSnapshot) -> String {
        guard let endpoint = snapshot.relayEndpoint, let serverId = snapshot.relayServerId else {
            return "Disabled"
        }
        return "\(snapshot.relayState.rawValue) \(endpoint) \(serverId)"
    }

    private func clientLine(_ client: HostClientStatus) -> String {
        var parts = [
            "\(client.transport.rawValue)",
            client.endpoint,
            client.state.rawValue,
            "cmds \(client.commandCount)"
        ]
        if client.invalidFrameCount > 0 {
            parts.append("invalid \(client.invalidFrameCount)")
        }
        if let latency = client.lastLatencyMillis {
            parts.append("latency \(latency) ms")
        }
        return parts.joined(separator: " · ")
    }

    private func clientSummary(_ snapshot: HostRuntimeSnapshot) -> String {
        guard let client = snapshot.clients.first(where: { $0.state == .connected }) ?? snapshot.clients.first else {
            return "None"
        }
        return clientLine(client)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = disabled(title)
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func statusActionItem(_ label: String, _ value: String) -> NSMenuItem {
        let item = actionItem("\(label): \(value)", #selector(showSetupGuide))
        item.attributedTitle = NSAttributedString(
            string: "\(label): \(value)",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleSyntheticCursor() {
        syntheticCursor.setEnabled(!syntheticCursor.isEnabled)
        render(latestSnapshot)
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func showSetupGuide() {
        DispatchQueue.main.async {
            self.setupWindowController.showAndFocus()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func loadStatusIcon() -> NSImage? {
        // The menu bar wants a monochrome template image so it follows the
        // system's light/dark rendering like every other status item.
        if let url = Bundle.main.url(forResource: "VibeAnywareMenuIconTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(
            systemSymbolName: "hand.draw",
            accessibilityDescription: "VibeAnyware"
        )
    }
}
