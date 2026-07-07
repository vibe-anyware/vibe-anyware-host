import Foundation

public enum MouseButton: String, CaseIterable, Codable, Equatable, Sendable {
    case left
    case right
}

public enum MouseButtonPhase: String, Codable, Equatable, Sendable {
    case down
    case up
    case click
}

public struct PointerDelta: Codable, Equatable, Sendable {
    public let dx: Double
    public let dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

public enum ScrollPhase: String, Codable, Equatable, Sendable {
    case begin
    case change
    case end
}

public struct MouseButtonCommand: Codable, Equatable, Sendable {
    public let button: MouseButton
    public let phase: MouseButtonPhase
    public let clickCount: Int

    public init(button: MouseButton, phase: MouseButtonPhase, clickCount: Int = 1) {
        self.button = button
        self.phase = phase
        self.clickCount = max(1, clickCount)
    }
}

public enum SpecialKey: String, CaseIterable, Codable, Equatable, Sendable {
    case `return`
    case delete
    case escape
    case tab
    case space
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
}

public enum ShortcutCommand: String, CaseIterable, Codable, Equatable, Sendable {
    case copy
    case paste
    case cut
    case selectAll
    case undo
    case redo
    case save
    case spotlight
    case appSwitcher
    case browserBack
    case browserForward
    case zoomIn
    case zoomOut
    case missionControl
    case appExpose
    case spaceLeft
    case spaceRight
}

public enum RemoteCommand: Codable, Equatable, Sendable {
    case mouseMove(PointerDelta)
    case mouseScroll(PointerDelta)
    case mouseScrollPhase(PointerDelta, ScrollPhase)
    case mouseButton(MouseButtonCommand)
    case text(String)
    case key(SpecialKey)
    case keyCombo(KeyCombo)
    case shortcut(ShortcutCommand)
    case ping

    private enum CodingKeys: String, CodingKey {
        case kind
        case dx
        case dy
        case button
        case phase
        case clickCount
        case text
        case key
        case shortcut
        case comboKey
        case command
        case option
        case control
        case shift
    }

    private enum Kind: String, Codable {
        case mouseMove
        case mouseScroll
        case mouseScrollPhase
        case mouseButton
        case text
        case key
        case keyCombo
        case shortcut
        case ping
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .mouseMove:
            self = try .mouseMove(Self.decodePointerDelta(from: container))
        case .mouseScroll:
            self = try .mouseScroll(Self.decodePointerDelta(from: container))
        case .mouseScrollPhase:
            let delta = try Self.decodePointerDelta(from: container)
            let phase = try container.decode(ScrollPhase.self, forKey: .phase)
            self = .mouseScrollPhase(delta, phase)
        case .mouseButton:
            let button = try container.decode(MouseButton.self, forKey: .button)
            let phase = try container.decode(MouseButtonPhase.self, forKey: .phase)
            let clickCount = try container.decodeIfPresent(Int.self, forKey: .clickCount) ?? 1
            self = .mouseButton(MouseButtonCommand(button: button, phase: phase, clickCount: clickCount))
        case .text:
            self = try .text(container.decode(String.self, forKey: .text))
        case .key:
            self = try .key(container.decode(SpecialKey.self, forKey: .key))
        case .keyCombo:
            self = try .keyCombo(
                KeyCombo(
                    key: container.decode(String.self, forKey: .comboKey),
                    command: container.decodeIfPresent(Bool.self, forKey: .command) ?? false,
                    option: container.decodeIfPresent(Bool.self, forKey: .option) ?? false,
                    control: container.decodeIfPresent(Bool.self, forKey: .control) ?? false,
                    shift: container.decodeIfPresent(Bool.self, forKey: .shift) ?? false
                )
            )
        case .shortcut:
            self = try .shortcut(container.decode(ShortcutCommand.self, forKey: .shortcut))
        case .ping:
            self = .ping
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .mouseMove(delta):
            try container.encode(Kind.mouseMove, forKey: .kind)
            try Self.encode(delta, into: &container)
        case let .mouseScroll(delta):
            try container.encode(Kind.mouseScroll, forKey: .kind)
            try Self.encode(delta, into: &container)
        case let .mouseScrollPhase(delta, phase):
            try container.encode(Kind.mouseScrollPhase, forKey: .kind)
            try Self.encode(delta, into: &container)
            try container.encode(phase, forKey: .phase)
        case let .mouseButton(command):
            try container.encode(Kind.mouseButton, forKey: .kind)
            try container.encode(command.button, forKey: .button)
            try container.encode(command.phase, forKey: .phase)
            try container.encode(command.clickCount, forKey: .clickCount)
        case let .text(text):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        case let .key(key):
            try container.encode(Kind.key, forKey: .kind)
            try container.encode(key, forKey: .key)
        case let .keyCombo(combo):
            try container.encode(Kind.keyCombo, forKey: .kind)
            try container.encode(combo.key, forKey: .comboKey)
            try container.encode(combo.command, forKey: .command)
            try container.encode(combo.option, forKey: .option)
            try container.encode(combo.control, forKey: .control)
            try container.encode(combo.shift, forKey: .shift)
        case let .shortcut(shortcut):
            try container.encode(Kind.shortcut, forKey: .kind)
            try container.encode(shortcut, forKey: .shortcut)
        case .ping:
            try container.encode(Kind.ping, forKey: .kind)
        }
    }

    private static func encode(
        _ delta: PointerDelta,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode(delta.dx, forKey: .dx)
        try container.encode(delta.dy, forKey: .dy)
    }

    private static func decodePointerDelta(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> PointerDelta {
        let dx = try container.decode(Double.self, forKey: .dx)
        let dy = try container.decode(Double.self, forKey: .dy)
        return PointerDelta(dx: dx, dy: dy)
    }
}
