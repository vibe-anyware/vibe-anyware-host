import AppKit
import Foundation

/// Draws the pointer as a real, borderless window that follows the tracked
/// cursor position.
///
/// macOS renders the normal cursor as a hardware overlay that the window
/// server composites separately — screen-mirroring / remote-desktop tools
/// (e.g. UU远程) frequently don't capture it, or hide the real cursor and
/// draw their own from their input channel. Because this app moves the cursor
/// outside that channel, the remote view shows no pointer. A regular window,
/// by contrast, is part of the composited desktop and therefore *is* captured,
/// so this overlay makes the pointer visible again on the mirrored screen.
@MainActor
final class SyntheticCursorOverlay {
    private let window: NSWindow
    private let imageView: NSImageView
    private let cursorSize: NSSize
    private let hotSpot: NSPoint
    private var primaryHeight: CGFloat

    init() {
        let cursor = NSCursor.arrow
        let image = cursor.image
        cursorSize = image.size
        hotSpot = cursor.hotSpot

        imageView = NSImageView(frame: NSRect(origin: .zero, size: cursorSize))
        imageView.image = image
        imageView.imageScaling = .scaleNone

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: cursorSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // High enough to sit above app windows, but a normal window level so
        // screen capture still includes it (unlike the shielding level).
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary
        ]
        window.contentView = imageView
        window.orderOut(nil)

        primaryHeight = SyntheticCursorOverlay.computePrimaryHeight()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Move the overlay so the arrow's hotspot sits on `cgPoint`, which is in
    /// global CoreGraphics display coordinates (origin at the top-left of the
    /// primary display, y increasing downward).
    func update(to cgPoint: CGPoint) {
        // CG global (top-left origin) → Cocoa global (bottom-left origin).
        let originX = cgPoint.x - hotSpot.x
        let originY = (primaryHeight - cgPoint.y) - (cursorSize.height - hotSpot.y)
        window.setFrameOrigin(NSPoint(x: originX, y: originY))
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    func hide() {
        window.orderOut(nil)
    }

    @objc private func screensChanged() {
        primaryHeight = SyntheticCursorOverlay.computePrimaryHeight()
    }

    private static func computePrimaryHeight() -> CGFloat {
        // The primary display is the one whose Cocoa frame origin is (0,0);
        // its height is the flip reference for the whole global space.
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        return primary?.frame.height ?? 0
    }
}

/// Owns the overlay and the on/off preference, and bridges pointer updates
/// (which arrive on the input-handling thread) onto the main thread.
@MainActor
final class SyntheticCursorController {
    static let defaultsKey = "VibeAnyware.syntheticCursorEnabled"
    /// How long the overlay lingers after the last remote pointer update before
    /// hiding itself. The overlay only tracks pointer moves the phone drives, so
    /// while nobody's controlling remotely it would just sit on screen as a
    /// second, static cursor next to the real one. Auto-hiding when idle means a
    /// local user sees only the real system cursor; the overlay reappears the
    /// instant the phone moves the pointer again (which is when a mirrored view
    /// needs it).
    private static let idleHideInterval: TimeInterval = 1.2

    private lazy var overlay = SyntheticCursorOverlay()
    private(set) var isEnabled: Bool
    private var hideWorkItem: DispatchWorkItem?

    init() {
        if ProcessInfo.processInfo.environment["VIBE_ANYWARE_SYNTHETIC_CURSOR"] != nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
        if !enabled {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            overlay.hide()
        }
    }

    /// Safe to call from any thread; hops to the main actor and no-ops when
    /// the feature is off.
    nonisolated func pointerMoved(to point: CGPoint) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled else { return }
            self.overlay.update(to: point)
            self.scheduleIdleHide()
        }
    }

    /// (Re)arm the idle timer that hides the overlay once remote pointer updates
    /// stop arriving, so it never lingers as a second cursor during local use.
    private func scheduleIdleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.overlay.hide()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleHideInterval, execute: work)
    }
}
