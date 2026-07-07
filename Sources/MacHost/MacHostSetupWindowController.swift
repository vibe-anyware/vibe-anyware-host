import AppKit

@MainActor
final class MacHostSetupWindowController: NSWindowController {
    private let statusStore: HostStatusStore
    private var observerID: UUID?
    private var latestSnapshot = HostRuntimeSnapshot()

    private let statusPill = SetupPillView()
    private let backgroundStep = SetupStepView(symbolName: "checkmark.circle.fill")
    private let accessibilityStep = SetupStepView(symbolName: "exclamationmark.triangle.fill")
    private let connectionStep = SetupStepView(symbolName: "antenna.radiowaves.left.and.right")
    private let mobileStep = SetupStepView(symbolName: "iphone")
    private let diagnosticsStep = SetupStepView(symbolName: "doc.text.magnifyingglass")

    private let permissionTitleLabel = SetupText.title("")
    private let permissionBodyLabel = SetupText.body("")
    private let permissionStatusLabel = SetupText.caption("")
    private let permissionChecklistStack = NSStackView()
    private let diagnosticsStack = NSStackView()
    private let logsStack = NSStackView()
    private let illustrationView = AccessibilityGuideIllustrationView()

    private var hostAppURL: URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/VibeAnyware.app")
    }

    init(statusStore: HostStatusStore) {
        self.statusStore = statusStore
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeAnyware Setup"
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        super.init(window: window)

        window.contentView = makeContentView()
        observerID = statusStore.observe { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.render(snapshot)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observerID {
            statusStore.removeObserver(observerID)
        }
    }

    func showAndFocus() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        render(latestSnapshot)
    }

    private func makeContentView() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = SetupTheme.surfacePrimary.cgColor

        let sidebar = makeSidebar()
        let content = makeMainContent()

        let layout = NSStackView(views: [sidebar, content])
        layout.orientation = .horizontal
        layout.alignment = .top
        layout.spacing = 0
        layout.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(layout)

        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            layout.topAnchor.constraint(equalTo: root.topAnchor),
            layout.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 260)
        ])

        return root
    }

    private func makeSidebar() -> NSView {
        let panel = SetupPanelView(fill: SetupTheme.surfaceSecondary, border: nil, radius: 0)
        panel.translatesAutoresizingMaskIntoConstraints = false

        let brandRow = makeBrandRow()
        let title = SetupText.title("VibeAnyware")
        let subtitle = SetupText.body("Setup, permission, and live diagnostics for this Mac.")
        subtitle.textColor = SetupTheme.textSecondary

        [backgroundStep, accessibilityStep, connectionStep, mobileStep, diagnosticsStep].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        let stack = NSStackView(views: [
            brandRow,
            SetupSpacer(height: 2),
            title,
            subtitle,
            SetupSpacer(height: 10),
            backgroundStep,
            accessibilityStep,
            connectionStep,
            mobileStep,
            diagnosticsStep
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 28),
            backgroundStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            accessibilityStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            connectionStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            mobileStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            diagnosticsStep.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return panel
    }

    private func makeBrandRow() -> NSView {
        let icon = NSImageView()
        icon.image = Self.loadBrandIcon()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let badge = SetupPanelView(fill: SetupTheme.surfaceElevated, border: SetupTheme.borderDefault, radius: 14)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)

        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 56),
            badge.heightAnchor.constraint(equalToConstant: 56),
            icon.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 6),
            icon.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -6),
            icon.topAnchor.constraint(equalTo: badge.topAnchor, constant: 6),
            icon.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -6)
        ])
        return badge
    }

    private func makeMainContent() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        let permissionCard = makePermissionCard()
        let diagnosticsCard = makeDiagnosticsCard()

        let stack = NSStackView(views: [header, permissionCard, diagnosticsCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -22),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissionCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            diagnosticsCard.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return view
    }

    private func makeHeader() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let title = SetupText.display("Setup")
        let subtitle = SetupText.body("Follow the checklist once. After that, the menu bar only needs to show live state.")
        subtitle.textColor = SetupTheme.textSecondary

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5
        textStack.translatesAutoresizingMaskIntoConstraints = false

        statusPill.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(textStack)
        container.addSubview(statusPill)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textStack.topAnchor.constraint(equalTo: container.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusPill.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusPill.centerYAnchor.constraint(equalTo: textStack.centerYAnchor),
            statusPill.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 20)
        ])

        return container
    }

    private func makePermissionCard() -> NSView {
        let card = SetupPanelView(fill: SetupTheme.surfaceElevated, border: SetupTheme.borderDefault, radius: 24)
        card.translatesAutoresizingMaskIntoConstraints = false

        permissionStatusLabel.textColor = SetupTheme.textSecondary

        permissionChecklistStack.orientation = .vertical
        permissionChecklistStack.alignment = .leading
        permissionChecklistStack.spacing = 10
        permissionChecklistStack.translatesAutoresizingMaskIntoConstraints = false

        let requestAccessButton = setupButton(
            title: "Request Access",
            symbolName: "hand.raised.fill",
            action: #selector(requestAccessibilityAccess),
            primary: true
        )
        let openSettingsButton = setupButton(
            title: "Open Settings",
            symbolName: "arrow.up.right.circle.fill",
            action: #selector(openAccessibilitySettings),
            primary: false
        )
        let resetPermissionButton = setupButton(
            title: "Reset & Request again",
            symbolName: "arrow.triangle.2.circlepath",
            action: #selector(resetAndRequestAccessibilityAccess),
            primary: false
        )
        let copyPathButton = setupButton(
            title: "Copy app path",
            symbolName: "doc.on.doc",
            action: #selector(copyHostAppPath),
            primary: false
        )
        let revealButton = setupButton(
            title: "Reveal app",
            symbolName: "folder",
            action: #selector(revealHostApp),
            primary: false
        )
        let restartButton = setupButton(
            title: "Restart host",
            symbolName: "arrow.clockwise",
            action: #selector(restartHost),
            primary: false
        )

        let primaryButtonRow = NSStackView(views: [requestAccessButton, openSettingsButton, resetPermissionButton])
        primaryButtonRow.orientation = .horizontal
        primaryButtonRow.alignment = .leading
        primaryButtonRow.spacing = 10

        let utilityButtonRow = NSStackView(views: [copyPathButton, revealButton, restartButton])
        utilityButtonRow.orientation = .horizontal
        utilityButtonRow.alignment = .leading
        utilityButtonRow.spacing = 10

        let buttonStack = NSStackView(views: [primaryButtonRow, utilityButtonRow])
        buttonStack.orientation = .vertical
        buttonStack.alignment = .leading
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let textColumn = NSStackView(views: [
            permissionStatusLabel,
            permissionTitleLabel,
            permissionBodyLabel,
            SetupSpacer(height: 4),
            permissionChecklistStack,
            SetupSpacer(height: 4),
            buttonStack
        ])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 10
        textColumn.translatesAutoresizingMaskIntoConstraints = false

        illustrationView.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [textColumn, illustrationView])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 24
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            textColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            illustrationView.widthAnchor.constraint(equalToConstant: 310),
            illustrationView.heightAnchor.constraint(equalToConstant: 260),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 306)
        ])

        return card
    }

    private func makeDiagnosticsCard() -> NSView {
        let card = SetupPanelView(fill: SetupTheme.surfaceSecondary, border: SetupTheme.borderSubtle, radius: 20)
        card.translatesAutoresizingMaskIntoConstraints = false

        let title = SetupText.title("Diagnostics")
        let subtitle = SetupText.body("Use this when the iOS app says connected but the Mac does not move.")
        subtitle.textColor = SetupTheme.textSecondary

        diagnosticsStack.orientation = .vertical
        diagnosticsStack.alignment = .leading
        diagnosticsStack.spacing = 8
        diagnosticsStack.translatesAutoresizingMaskIntoConstraints = false

        logsStack.orientation = .vertical
        logsStack.alignment = .leading
        logsStack.spacing = 7
        logsStack.translatesAutoresizingMaskIntoConstraints = false

        let logHeader = SetupText.caption("Recent logs")
        logHeader.textColor = SetupTheme.textSecondary

        let grid = NSStackView(views: [diagnosticsStack, logsStack])
        grid.orientation = .horizontal
        grid.alignment = .top
        grid.spacing = 26
        grid.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, subtitle, SetupSpacer(height: 4), grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        logsStack.addArrangedSubview(logHeader)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            diagnosticsStack.widthAnchor.constraint(equalTo: grid.widthAnchor, multiplier: 0.48),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])

        return card
    }

    private func setupButton(title: String, symbolName: String, action: Selector, primary: Bool) -> NSButton {
        SetupActionButton(
            title: title,
            symbolName: symbolName,
            target: self,
            action: action,
            primary: primary
        )
    }

    private func render(_ snapshot: HostRuntimeSnapshot) {
        latestSnapshot = snapshot
        renderSidebar(snapshot)
        renderPermission(snapshot)
        renderDiagnostics(snapshot)
    }

    private func renderSidebar(_ snapshot: HostRuntimeSnapshot) {
        backgroundStep.configure(
            title: "Background service",
            subtitle: "LaunchAgent is running",
            state: .complete
        )
        accessibilityStep.configure(
            title: "Accessibility",
            subtitle: snapshot.accessibilityTrusted ? "Permission granted" : "Action required",
            state: snapshot.accessibilityTrusted ? .complete : .attention
        )
        let networkReady = snapshot.lanState == .connected || snapshot.relayState == .connected
        connectionStep.configure(
            title: "Connection mode",
            subtitle: networkReady ? networkSummary(snapshot) : "Waiting for LAN or relay",
            state: networkReady ? .complete : .pending
        )
        mobileStep.configure(
            title: "Mobile clients",
            subtitle: snapshot.activeClientCount > 0 ? "\(snapshot.activeClientCount) connected" : "No phone connected",
            state: snapshot.activeClientCount > 0 ? .complete : .pending
        )
        diagnosticsStep.configure(
            title: "Diagnostics",
            subtitle: "Logs and latency",
            state: .pending
        )
    }

    private func renderPermission(_ snapshot: HostRuntimeSnapshot) {
        statusPill.configure(
            title: snapshot.accessibilityTrusted ? "Ready" : "Needs Accessibility",
            color: snapshot.accessibilityTrusted ? SetupTheme.statusSuccess : SetupTheme.statusWarning
        )
        permissionStatusLabel.stringValue = snapshot.accessibilityTrusted ? "ACCESSIBILITY GRANTED" : "ACTION REQUIRED"
        permissionStatusLabel.textColor = snapshot.accessibilityTrusted ? SetupTheme.statusSuccess : SetupTheme.statusWarning

        if snapshot.accessibilityTrusted {
            permissionTitleLabel.stringValue = "This Mac can receive pointer and keyboard events."
            permissionBodyLabel.stringValue = "Accessibility permission is granted for the current VibeAnyware.app. Connect the iOS app by LAN or relay, then watch Mobile clients and latency below."
            replaceChecklist([
                "Keep only the current VibeAnyware.app row in Accessibility.",
                "Open the iOS app and connect using LAN or relay.",
                "If commands do not move the pointer, check latency and invalid frame counts below."
            ])
        } else {
            permissionTitleLabel.stringValue = "Grant permission for the current host app."
            permissionBodyLabel.stringValue = "Click Request Access first. macOS will show its permission dialog and open Accessibility settings with this app ready to enable. Use Reset & Request again only if an old entry is stuck."
            replaceChecklist([
                "Click Request Access.",
                "In System Settings, enable VibeAnyware with this app icon.",
                "If it already looks enabled but still says Missing, click Reset & Request again.",
                "Manual fallback: reveal \(hostAppURL.path) and drag it into Accessibility.",
                "Return here. The status should change to Ready automatically; use Restart host if it does not."
            ])
        }
        illustrationView.isPermissionGranted = snapshot.accessibilityTrusted
        illustrationView.hostAppName = hostAppURL.lastPathComponent
        illustrationView.needsDisplay = true
    }

    private func renderDiagnostics(_ snapshot: HostRuntimeSnapshot) {
        replaceArrangedSubviews(in: diagnosticsStack, with: [
            diagnosticRow("LAN", lanStatus(snapshot), stateColor(for: snapshot.lanState)),
            diagnosticRow("LAN command key", snapshot.lanCommandKeyConfigured ? "Configured" : "Missing", snapshot.lanCommandKeyConfigured ? SetupTheme.statusSuccess : SetupTheme.statusError),
            diagnosticRow("Relay", relayStatus(snapshot), stateColor(for: snapshot.relayState)),
            diagnosticRow("Mobile clients", clientSummary(snapshot), snapshot.activeClientCount > 0 ? SetupTheme.statusSuccess : SetupTheme.textSecondary)
        ])

        var logViews: [NSView] = [logHeader()]
        if snapshot.recentLogs.isEmpty {
            logViews.append(SetupText.body("No logs yet"))
        } else {
            logViews.append(contentsOf: snapshot.recentLogs.prefix(5).map { logLine($0) })
        }
        replaceArrangedSubviews(in: logsStack, with: logViews)
    }

    private func replaceChecklist(_ items: [String]) {
        let views = items.enumerated().map { index, text in
            checklistRow(number: index + 1, text: text)
        }
        replaceArrangedSubviews(in: permissionChecklistStack, with: views)
    }

    private func replaceArrangedSubviews(in stack: NSStackView, with views: [NSView]) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        views.forEach(stack.addArrangedSubview)
    }

    private func checklistRow(number: Int, text: String) -> NSView {
        let numberLabel = SetupText.caption("\(number)")
        numberLabel.alignment = .center
        numberLabel.textColor = SetupTheme.textPrimary

        let circle = SetupPanelView(fill: SetupTheme.surfaceSecondary, border: SetupTheme.borderDefault, radius: 11)
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(numberLabel)
        numberLabel.translatesAutoresizingMaskIntoConstraints = false

        let label = SetupText.body(text)
        label.textColor = SetupTheme.textPrimary

        let row = NSStackView(views: [circle, label])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 22),
            circle.heightAnchor.constraint(equalToConstant: 22),
            numberLabel.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            numberLabel.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 470)
        ])

        return row
    }

    private func diagnosticRow(_ label: String, _ value: String, _ color: NSColor) -> NSView {
        let title = SetupText.caption(label.uppercased())
        title.textColor = SetupTheme.textSecondary
        let valueLabel = SetupText.body(value)
        valueLabel.textColor = color
        valueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)

        let stack = NSStackView(views: [title, valueLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func logHeader() -> NSView {
        let label = SetupText.caption("RECENT LOGS")
        label.textColor = SetupTheme.textSecondary
        return label
    }

    private func logLine(_ text: String) -> NSView {
        let label = SetupText.body(text)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = SetupTheme.textSecondary
        return label
    }

    private func networkSummary(_ snapshot: HostRuntimeSnapshot) -> String {
        if let port = snapshot.lanPort, snapshot.lanState == .connected {
            return "LAN :\(port)"
        }
        if snapshot.relayState == .connected {
            return "Relay connected"
        }
        return "Waiting"
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

    private func clientSummary(_ snapshot: HostRuntimeSnapshot) -> String {
        guard let client = snapshot.clients.first(where: { $0.state == .connected }) ?? snapshot.clients.first else {
            return "No mobile client connected"
        }

        var parts = [client.transport.rawValue, client.endpoint, client.state.rawValue, "cmds \(client.commandCount)"]
        if let latency = client.lastLatencyMillis {
            parts.append("\(latency) ms")
        }
        if client.invalidFrameCount > 0 {
            parts.append("invalid \(client.invalidFrameCount)")
        }
        return parts.joined(separator: " / ")
    }

    private func stateColor(for state: HostConnectionState) -> NSColor {
        switch state {
        case .connected:
            SetupTheme.statusSuccess
        case .connecting:
            SetupTheme.statusWarning
        case .failed:
            SetupTheme.statusError
        case .disconnected:
            SetupTheme.textSecondary
        }
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func requestAccessibilityAccess() {
        _ = MacInputController.requestAccessibilityTrustPrompt()
        openAccessibilitySettings()
        refreshAccessibilityStatusSoon()
    }

    @objc private func resetAndRequestAccessibilityAccess() {
        resetAccessibilityPermission()
        _ = MacInputController.requestAccessibilityTrustPrompt()
        openAccessibilitySettings()
        refreshAccessibilityStatusSoon()
    }

    @objc private func copyHostAppPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hostAppURL.path, forType: .string)
    }

    @objc private func revealHostApp() {
        NSWorkspace.shared.activateFileViewerSelecting([hostAppURL])
    }

    @objc private func restartHost() {
        NSApp.terminate(nil)
    }

    private func resetAccessibilityPermission() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "app.vibeanyware.host"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            showResetFailed(error.localizedDescription)
        }
        statusStore.updateAccessibilityTrusted(MacInputController.isAccessibilityTrusted())
    }

    private func refreshAccessibilityStatusSoon() {
        statusStore.updateAccessibilityTrusted(MacInputController.isAccessibilityTrusted())
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.statusStore.updateAccessibilityTrusted(MacInputController.isAccessibilityTrusted())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.statusStore.updateAccessibilityTrusted(MacInputController.isAccessibilityTrusted())
        }
    }

    private func showResetFailed(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not reset Accessibility permission"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func loadBrandIcon() -> NSImage? {
        let candidates = [
            Bundle.main.url(forResource: "VibeAnywareMenuIcon", withExtension: "png"),
            Bundle.main.url(forResource: "VibeAnyware", withExtension: "icns")
        ].compactMap { $0 }
        guard let url = candidates.first else {
            return NSImage(systemSymbolName: "rectangle.connected.to.line.below", accessibilityDescription: "VibeAnyware")
        }
        return NSImage(contentsOf: url)
    }
}

private enum SetupStepState {
    case complete
    case attention
    case pending
}

private final class SetupStepView: SetupPanelView {
    private let iconView = NSImageView()
    private let titleLabel = SetupText.heading("")
    private let subtitleLabel = SetupText.caption("")

    init(symbolName: String) {
        super.init(fill: SetupTheme.surfacePrimary, border: SetupTheme.borderSubtle, radius: 14)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 17, weight: .semibold)

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let row = NSStackView(views: [iconView, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, subtitle: String, state: SetupStepState) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.textColor = SetupTheme.textSecondary

        switch state {
        case .complete:
            iconView.contentTintColor = SetupTheme.statusSuccess
            update(fill: SetupTheme.surfacePrimary, border: SetupTheme.borderSubtle)
        case .attention:
            iconView.contentTintColor = SetupTheme.statusWarning
            update(fill: SetupTheme.warningSurface, border: SetupTheme.statusWarning.withAlphaComponent(0.35))
        case .pending:
            iconView.contentTintColor = SetupTheme.textSecondary
            update(fill: SetupTheme.surfacePrimary, border: SetupTheme.borderSubtle)
        }
    }
}

private final class SetupPillView: SetupPanelView {
    private let dotView = SetupDotView(color: SetupTheme.textSecondary)
    private let label = SetupText.heading("")

    init() {
        super.init(fill: SetupTheme.surfaceSecondary, border: SetupTheme.borderDefault, radius: 18)
        let stack = NSStackView(views: [dotView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            dotView.widthAnchor.constraint(equalToConstant: 9),
            dotView.heightAnchor.constraint(equalToConstant: 9)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, color: NSColor) {
        label.stringValue = title
        dotView.color = color
        update(fill: SetupTheme.surfaceSecondary, border: color.withAlphaComponent(0.45))
    }
}

private final class SetupActionButton: NSButton {
    private let primary: Bool

    init(title: String, symbolName: String, target: AnyObject?, action: Selector, primary: Bool) {
        self.primary = primary
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        imagePosition = .imageLeading
        imageHugsTitle = true
        isBordered = false
        focusRingType = .none
        controlSize = .large
        font = .systemFont(ofSize: 13, weight: .semibold)
        contentTintColor = primary ? .white : SetupTheme.accentPrimary
        attributedTitle = Self.title(title, primary: primary)
        attributedAlternateTitle = Self.title(title, primary: primary)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 22, height: 34)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = primary ? SetupTheme.accentPrimary : SetupTheme.surfaceSecondary
        let border = primary ? SetupTheme.accentPrimary : SetupTheme.borderDefault
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        (isHighlighted ? fill.blended(withFraction: 0.18, of: .black) ?? fill : fill).setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
        super.draw(dirtyRect)
    }

    private static func title(_ title: String, primary: Bool) -> NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: primary ? NSColor.white : SetupTheme.textPrimary
            ]
        )
    }
}

private class SetupPanelView: NSView {
    private var fill: NSColor
    private var border: NSColor?
    private let radius: CGFloat

    init(fill: NSColor, border: NSColor?, radius: CGFloat) {
        self.fill = fill
        self.border = border
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border?.cgColor
        layer?.borderWidth = border == nil ? 0 : 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(fill: NSColor, border: NSColor?) {
        self.fill = fill
        self.border = border
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border?.cgColor
        layer?.borderWidth = border == nil ? 0 : 1
    }
}

private final class SetupDotView: NSView {
    var color: NSColor {
        didSet {
            layer?.backgroundColor = color.cgColor
        }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4.5
        layer?.backgroundColor = color.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class AccessibilityGuideIllustrationView: NSView {
    var isPermissionGranted = false
    var hostAppName = "VibeAnyware.app"

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = bounds.insetBy(dx: 2, dy: 2)
        let panelPath = NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18)
        SetupTheme.surfaceSecondary.setFill()
        panelPath.fill()
        SetupTheme.borderDefault.setStroke()
        panelPath.lineWidth = 1
        panelPath.stroke()

        drawWindowControls(in: bounds)
        drawSettingsMock(in: bounds.insetBy(dx: 18, dy: 34))
        drawCallout(in: bounds)
    }

    private func drawWindowControls(in rect: NSRect) {
        let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 18 + CGFloat(index * 18), y: rect.minY + 16, width: 9, height: 9)).fill()
        }
    }

    private func drawSettingsMock(in rect: NSRect) {
        let sidebar = NSRect(x: rect.minX, y: rect.minY, width: 88, height: rect.height)
        SetupTheme.surfacePrimary.setFill()
        NSBezierPath(roundedRect: sidebar, xRadius: 12, yRadius: 12).fill()

        let search = NSRect(x: sidebar.minX + 10, y: sidebar.minY + 14, width: sidebar.width - 20, height: 20)
        SetupTheme.surfaceElevated.setFill()
        NSBezierPath(roundedRect: search, xRadius: 10, yRadius: 10).fill()

        let selected = NSRect(x: sidebar.minX + 10, y: sidebar.minY + 64, width: sidebar.width - 20, height: 26)
        SetupTheme.accentPrimary.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: selected, xRadius: 8, yRadius: 8).fill()

        let listX = sidebar.maxX + 18
        drawText("Privacy & Security", at: NSPoint(x: listX, y: rect.minY + 12), font: .systemFont(ofSize: 13, weight: .semibold), color: SetupTheme.textPrimary)
        drawText("Accessibility", at: NSPoint(x: listX, y: rect.minY + 38), font: .systemFont(ofSize: 24, weight: .semibold), color: SetupTheme.textPrimary)

        let row = NSRect(x: listX, y: rect.minY + 90, width: rect.maxX - listX - 16, height: 42)
        SetupTheme.surfaceElevated.setFill()
        NSBezierPath(roundedRect: row, xRadius: 12, yRadius: 12).fill()

        let appIcon = NSRect(x: row.minX + 12, y: row.minY + 11, width: 20, height: 20)
        SetupTheme.accentPrimary.setFill()
        NSBezierPath(roundedRect: appIcon, xRadius: 5, yRadius: 5).fill()
        drawText(hostAppName, at: NSPoint(x: row.minX + 42, y: row.minY + 12), font: .systemFont(ofSize: 13, weight: .semibold), color: SetupTheme.textPrimary)

        drawToggle(in: NSRect(x: row.maxX - 46, y: row.minY + 11, width: 34, height: 20))
        drawMinusButton(at: NSPoint(x: row.minX + 16, y: row.maxY + 34))
    }

    private func drawToggle(in rect: NSRect) {
        let color = isPermissionGranted ? SetupTheme.statusSuccess : SetupTheme.textTertiary
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        NSColor.white.setFill()
        let knobX = isPermissionGranted ? rect.maxX - 18 : rect.minX + 2
        NSBezierPath(ovalIn: NSRect(x: knobX, y: rect.minY + 2, width: 16, height: 16)).fill()
    }

    private func drawMinusButton(at point: NSPoint) {
        SetupTheme.surfaceElevated.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x, y: point.y, width: 22, height: 22)).fill()
        SetupTheme.textSecondary.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: point.x + 7, y: point.y + 11))
        line.line(to: NSPoint(x: point.x + 15, y: point.y + 11))
        line.lineWidth = 1.6
        line.stroke()
    }

    private func drawCallout(in rect: NSRect) {
        let calloutColor = isPermissionGranted ? SetupTheme.statusSuccess : SetupTheme.statusError
        calloutColor.setStroke()
        let callout = NSBezierPath(roundedRect: NSRect(x: rect.maxX - 78, y: rect.minY + 124, width: 52, height: 36), xRadius: 18, yRadius: 18)
        callout.lineWidth = 3
        callout.stroke()

        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: rect.maxX - 92, y: rect.minY + 204))
        arrow.line(to: NSPoint(x: rect.maxX - 52, y: rect.minY + 158))
        arrow.lineWidth = 2.5
        arrow.stroke()

        drawText(
            isPermissionGranted ? "Enabled" : "Turn this on",
            at: NSPoint(x: rect.minX + 20, y: rect.maxY - 36),
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: calloutColor
        )
    }

    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        text.draw(at: point, withAttributes: attributes)
    }
}

@MainActor
private enum SetupText {
    static func display(_ value: String) -> NSTextField {
        label(value, size: 28, weight: .bold, color: SetupTheme.textPrimary)
    }

    static func title(_ value: String) -> NSTextField {
        label(value, size: 21, weight: .semibold, color: SetupTheme.textPrimary)
    }

    static func heading(_ value: String) -> NSTextField {
        label(value, size: 14, weight: .semibold, color: SetupTheme.textPrimary)
    }

    static func body(_ value: String) -> NSTextField {
        let label = label(value, size: 14, weight: .regular, color: SetupTheme.textPrimary)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }

    static func caption(_ value: String) -> NSTextField {
        label(value, size: 11, weight: .semibold, color: SetupTheme.textSecondary)
    }

    private static func label(_ value: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isSelectable = false
        return label
    }
}

private final class SetupSpacer: NSView {
    init(height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private enum SetupTheme {
    static let surfacePrimary = NSColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)
    static let surfaceSecondary = NSColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1)
    static let surfaceElevated = NSColor(red: 0.13, green: 0.15, blue: 0.19, alpha: 1)
    static let warningSurface = NSColor(red: 0.18, green: 0.14, blue: 0.08, alpha: 1)
    static let textPrimary = NSColor(red: 0.95, green: 0.97, blue: 0.99, alpha: 1)
    static let textSecondary = NSColor(red: 0.66, green: 0.70, blue: 0.76, alpha: 1)
    static let textTertiary = NSColor(red: 0.44, green: 0.47, blue: 0.53, alpha: 1)
    static let borderDefault = NSColor(red: 0.19, green: 0.22, blue: 0.28, alpha: 1)
    static let borderSubtle = NSColor(red: 0.14, green: 0.17, blue: 0.21, alpha: 1)
    static let accentPrimary = NSColor(red: 0.40, green: 0.64, blue: 1.00, alpha: 1)
    static let statusSuccess = NSColor(red: 0.32, green: 0.82, blue: 0.49, alpha: 1)
    static let statusWarning = NSColor(red: 0.96, green: 0.75, blue: 0.31, alpha: 1)
    static let statusError = NSColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1)
}
