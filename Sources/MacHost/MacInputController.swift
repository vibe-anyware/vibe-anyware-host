import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation

protocol MacInputControlling: AnyObject {
    func handle(_ command: RemoteCommand)
}

struct MouseEventRequest: Equatable {
    let type: CGEventType
    let button: CGMouseButton
    let location: CGPoint
    let clickCount: Int
}

struct ScrollEventRequest: Equatable {
    let dx: Int32
    let dy: Int32
    let phase: ScrollPhase
}

protocol MouseEventPosting {
    var location: CGPoint { get }
    func warp(to point: CGPoint)
    func postMouse(_ request: MouseEventRequest)
}

protocol ScrollEventPosting {
    func postScroll(_ request: ScrollEventRequest)
}

final class MacInputController: MacInputControlling {
    private let mouseEventPoster: MouseEventPosting
    private let scrollEventPoster: ScrollEventPosting
    private var pressedButton: MouseButton?
    private var pressedClickCount = 1

    /// Notified with the driven pointer position (global CoreGraphics coords)
    /// on every move and button event, so an on-screen overlay can follow the
    /// cursor for screen-mirroring tools that don't capture the real one.
    var onPointerMoved: ((CGPoint) -> Void)?

    /// The pointer position we drive, tracked internally instead of re-read
    /// from the OS on every move. Screen-capture / remote-desktop tools (e.g.
    /// UU远程) can stop the OS cursor read-back from advancing while their
    /// input tap is active; accumulating relative deltas against a frozen
    /// read makes the cursor jitter in place. Owning the position here keeps
    /// motion smooth regardless of who else is watching the event stream.
    private var trackedLocation: CGPoint?
    private var lastPointerActivityAt: Date?
    private var cachedDisplayBounds: CGRect?
    /// After this much idle time we re-read the real cursor, so a pointer the
    /// user moved by other means (physical mouse, another app) is picked up.
    private let pointerResyncIdleInterval: TimeInterval = 1.5
    private let debugPointer = ProcessInfo.processInfo.environment["REMOTETRACKPAD_DEBUG_POINTER"] != nil
    private var debugMoveCounter = 0

    init(
        mouseEventPoster: MouseEventPosting? = nil,
        scrollEventPoster: ScrollEventPosting? = nil
    ) {
        let eventSource = CGEventSource(stateID: .hidSystemState)
        self.mouseEventPoster = mouseEventPoster ?? LiveMouseEventPoster(eventSource: eventSource)
        self.scrollEventPoster = scrollEventPoster ?? LiveScrollEventPoster(eventSource: eventSource)
    }

    func handle(_ command: RemoteCommand) {
        switch command {
        case let .mouseMove(delta):
            movePointer(by: delta)
        case let .mouseScroll(delta):
            scroll(by: delta, phase: .change)
        case let .mouseScrollPhase(delta, phase):
            scroll(by: delta, phase: phase)
        case let .mouseButton(command):
            handleMouseButton(command)
        case let .text(text):
            type(text)
        case let .key(key):
            postKey(key.virtualKeyCode)
        case let .keyCombo(combo):
            postKeyCombo(combo)
        case let .shortcut(shortcut):
            postShortcut(shortcut)
        case .ping:
            break
        }
    }

    static func requestAccessibilityTrustIfNeeded() {
        if !isAccessibilityTrusted() {
            print("Accessibility permission is required for mouse and keyboard control.")
        }
    }

    static func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    static func requestAccessibilityTrustPrompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func movePointer(by delta: PointerDelta) {
        let base = pointerBaseLocation()
        // Read the real cursor for diagnostics only: comparing it against our
        // target after the warp reveals whether the OS read-back is frozen
        // (UU远程-style) or the warp itself is being ignored.
        let realBeforeWarp = debugPointer ? mouseEventPoster.location : base
        let target = clampToDisplays(CGPoint(x: base.x + delta.dx, y: base.y + delta.dy))

        trackedLocation = target
        lastPointerActivityAt = Date()
        onPointerMoved?(target)

        // Warp the cursor to the target first: unlike a posted `.mouseMoved`,
        // `CGWarpMouseCursorPosition` repositions the pointer directly and is
        // never dropped by the event-suppression window. We still post the
        // move/drag event so tracking areas, hover states, and drags update.
        mouseEventPoster.warp(to: target)

        if let pressedButton {
            postMouse(
                type: pressedButton.draggedEventType,
                button: pressedButton.cgMouseButton,
                at: target,
                clickCount: pressedClickCount
            )
        } else {
            postMouse(type: .mouseMoved, button: .left, at: target, clickCount: 0)
        }

        if debugPointer {
            debugMoveCounter += 1
            if debugMoveCounter % 20 == 0 {
                let realAfterWarp = mouseEventPoster.location
                debugLog(
                    "[pointer] base=\(fmt(base)) delta=(\(Int(delta.dx)),\(Int(delta.dy))) "
                    + "target=\(fmt(target)) realBefore=\(fmt(realBeforeWarp)) realAfter=\(fmt(realAfterWarp))"
                )
            }
        }
    }

    /// Where the next relative move accumulates from. Uses our internally
    /// tracked position while the pointer is actively being driven, and only
    /// falls back to the (possibly frozen) OS read after a spell of inactivity.
    private func pointerBaseLocation() -> CGPoint {
        if let tracked = trackedLocation,
           let last = lastPointerActivityAt,
           Date().timeIntervalSince(last) < pointerResyncIdleInterval {
            return tracked
        }
        // Resyncing from the real cursor: also refresh the display union in
        // case the screen arrangement changed while we were idle.
        cachedDisplayBounds = nil
        return mouseEventPoster.location
    }

    private func clampToDisplays(_ point: CGPoint) -> CGPoint {
        let bounds = displayBounds()
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            return point
        }
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1)
        )
    }

    private func displayBounds() -> CGRect {
        if let cached = cachedDisplayBounds {
            return cached
        }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return .null
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return .null
        }
        var union = CGRect.null
        for id in ids {
            union = union.union(CGDisplayBounds(id))
        }
        cachedDisplayBounds = union
        return union
    }

    private func fmt(_ p: CGPoint) -> String {
        "(\(Int(p.x)),\(Int(p.y)))"
    }

    private func debugLog(_ message: String) {
        guard debugPointer else { return }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private func scroll(by delta: PointerDelta, phase: ScrollPhase) {
        let wheel1 = Int32(delta.dy.rounded())
        let wheel2 = Int32(delta.dx.rounded())
        scrollEventPoster.postScroll(ScrollEventRequest(dx: wheel2, dy: wheel1, phase: phase))
    }

    private func handleMouseButton(_ command: MouseButtonCommand) {
        // Click/press at the pointer we actually drive, not the OS read-back,
        // so a click after a move lands where the cursor visually is and a
        // click-drag accumulates from the right spot.
        let location = pointerBaseLocation()
        trackedLocation = location
        lastPointerActivityAt = Date()
        onPointerMoved?(location)
        let button = command.button.cgMouseButton

        switch command.phase {
        case .down:
            pressedButton = command.button
            pressedClickCount = command.clickCount
            postMouse(type: command.button.downEventType, button: button, at: location, clickCount: command.clickCount)
        case .up:
            postMouse(type: command.button.upEventType, button: button, at: location, clickCount: command.clickCount)
            if pressedButton == command.button {
                pressedButton = nil
                pressedClickCount = 1
            }
        case .click:
            postMouse(type: command.button.downEventType, button: button, at: location, clickCount: command.clickCount)
            postMouse(type: command.button.upEventType, button: button, at: location, clickCount: command.clickCount)
        }
    }

    private func postMouse(type: CGEventType, button: CGMouseButton, at location: CGPoint, clickCount: Int) {
        mouseEventPoster.postMouse(
            MouseEventRequest(
                type: type,
                button: button,
                location: location,
                clickCount: clickCount
            )
        )
    }

    private func type(_ text: String) {
        for character in text {
            postUnicode(String(character))
        }
    }

    private func postUnicode(_ text: String) {
        let characters = Array(text.utf16)
        guard !characters.isEmpty else {
            return
        }

        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)

        characters.withUnsafeBufferPointer { buffer in
            keyDown?.keyboardSetUnicodeString(
                stringLength: characters.count,
                unicodeString: buffer.baseAddress
            )
            keyUp?.keyboardSetUnicodeString(
                stringLength: characters.count,
                unicodeString: buffer.baseAddress
            )
        }

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func postShortcut(_ shortcut: ShortcutCommand) {
        // Space/Mission Control navigation ignores plain synthesized key
        // events on modern macOS; System Events posting passes the filter.
        if let navigationKeyCode = shortcut.systemEventsNavigationKeyCode {
            postSystemEventsControlKey(navigationKeyCode)
            return
        }

        let mapping = shortcut.keyMapping
        postKey(mapping.keyCode, flags: mapping.flags)
    }

    private func postSystemEventsControlKey(_ keyCode: Int) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = [
            "-e",
            "tell application \"System Events\" to key code \(keyCode) using control down"
        ]
        try? task.run()
    }

    private func postKeyCombo(_ combo: KeyCombo) {
        guard let keyCode = KeyComboCatalog.virtualKeyCode(for: combo.key) else {
            return
        }

        var flags: CGEventFlags = []
        if combo.command {
            flags.insert(.maskCommand)
        }
        if combo.option {
            flags.insert(.maskAlternate)
        }
        if combo.control {
            flags.insert(.maskControl)
        }
        if combo.shift {
            flags.insert(.maskShift)
        }

        postKey(CGKeyCode(keyCode), flags: flags)
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }

    private struct LiveMouseEventPoster: MouseEventPosting {
        let eventSource: CGEventSource?

        var location: CGPoint {
            CGEvent(source: nil)?.location ?? .zero
        }

        func warp(to point: CGPoint) {
            // Repositions the cursor directly through the window server, which
            // the event-suppression window can't drop the way it drops a
            // synthesized `.mouseMoved`. We deliberately do NOT touch
            // `CGAssociateMouseAndMouseCursorPosition` or the source's
            // suppression interval — those are global/shared state and were
            // observed to break click and scroll delivery.
            CGWarpMouseCursorPosition(point)
        }

        func postMouse(_ request: MouseEventRequest) {
            guard let event = CGEvent(
                mouseEventSource: eventSource,
                mouseType: request.type,
                mouseCursorPosition: request.location,
                mouseButton: request.button
            ) else {
                return
            }

            if request.clickCount > 0 {
                event.setIntegerValueField(
                    .mouseEventClickState,
                    value: Int64(request.clickCount)
                )
            }

            event.post(tap: .cghidEventTap)
        }
    }

    private struct LiveScrollEventPoster: ScrollEventPosting {
        let eventSource: CGEventSource?

        func postScroll(_ request: ScrollEventRequest) {
            guard let event = CGEvent(
                scrollWheelEvent2Source: eventSource,
                units: .pixel,
                wheelCount: 2,
                wheel1: request.dy,
                wheel2: request.dx,
                wheel3: 0
            ) else {
                return
            }

            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: request.phase.cgEventValue)
            event.post(tap: .cghidEventTap)
        }
    }
}

private extension MouseButton {
    var cgMouseButton: CGMouseButton {
        switch self {
        case .left:
            .left
        case .right:
            .right
        }
    }

    var downEventType: CGEventType {
        switch self {
        case .left:
            .leftMouseDown
        case .right:
            .rightMouseDown
        }
    }

    var upEventType: CGEventType {
        switch self {
        case .left:
            .leftMouseUp
        case .right:
            .rightMouseUp
        }
    }

    var draggedEventType: CGEventType {
        switch self {
        case .left:
            .leftMouseDragged
        case .right:
            .rightMouseDragged
        }
    }
}

private extension SpecialKey {
    var virtualKeyCode: CGKeyCode {
        switch self {
        case .return:
            36
        case .delete:
            51
        case .escape:
            53
        case .tab:
            48
        case .space:
            49
        case .arrowUp:
            126
        case .arrowDown:
            125
        case .arrowLeft:
            123
        case .arrowRight:
            124
        }
    }
}

private extension ScrollPhase {
    var cgEventValue: Int64 {
        switch self {
        case .begin:
            1
        case .change:
            2
        case .end:
            4
        }
    }
}

private struct KeyMapping {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

private extension ShortcutCommand {
    /// Arrow key code for shortcuts that must be posted through System
    /// Events (Ctrl+arrow navigation); nil for regular shortcuts.
    var systemEventsNavigationKeyCode: Int? {
        switch self {
        case .missionControl:
            126
        case .appExpose:
            125
        case .spaceLeft:
            123
        case .spaceRight:
            124
        default:
            nil
        }
    }

    var keyMapping: KeyMapping {
        switch self {
        case .copy:
            KeyMapping(keyCode: 8, flags: .maskCommand)
        case .paste:
            KeyMapping(keyCode: 9, flags: .maskCommand)
        case .cut:
            KeyMapping(keyCode: 7, flags: .maskCommand)
        case .selectAll:
            KeyMapping(keyCode: 0, flags: .maskCommand)
        case .undo:
            KeyMapping(keyCode: 6, flags: .maskCommand)
        case .redo:
            KeyMapping(keyCode: 6, flags: [.maskCommand, .maskShift])
        case .save:
            KeyMapping(keyCode: 1, flags: .maskCommand)
        case .spotlight:
            KeyMapping(keyCode: 49, flags: .maskCommand)
        case .appSwitcher:
            KeyMapping(keyCode: 48, flags: .maskCommand)
        case .browserBack:
            KeyMapping(keyCode: 33, flags: .maskCommand)
        case .browserForward:
            KeyMapping(keyCode: 30, flags: .maskCommand)
        case .zoomIn:
            KeyMapping(keyCode: 24, flags: .maskCommand)
        case .zoomOut:
            KeyMapping(keyCode: 27, flags: .maskCommand)
        case .missionControl:
            KeyMapping(keyCode: 126, flags: .maskControl)
        case .appExpose:
            KeyMapping(keyCode: 125, flags: .maskControl)
        case .spaceLeft:
            KeyMapping(keyCode: 123, flags: .maskControl)
        case .spaceRight:
            KeyMapping(keyCode: 124, flags: .maskControl)
        }
    }
}
