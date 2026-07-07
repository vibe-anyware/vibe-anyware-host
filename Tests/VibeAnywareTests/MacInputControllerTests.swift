import CoreGraphics
import XCTest

final class MacInputControllerTests: XCTestCase {
    func test_doubleClickPostsMouseDownAndUpWithClickCountTwo() {
        let poster = RecordingMouseEventPoster(location: CGPoint(x: 40, y: 80))
        let controller = MacInputController(mouseEventPoster: poster)

        controller.handle(.mouseButton(MouseButtonCommand(button: .left, phase: .click, clickCount: 2)))

        XCTAssertEqual(
            poster.requests,
            [
                MouseEventRequest(type: .leftMouseDown, button: .left, location: CGPoint(x: 40, y: 80), clickCount: 2),
                MouseEventRequest(type: .leftMouseUp, button: .left, location: CGPoint(x: 40, y: 80), clickCount: 2)
            ]
        )
    }

    func test_mouseMoveWhileLeftButtonIsDownPostsDraggedEvent() {
        let poster = RecordingMouseEventPoster(location: CGPoint(x: 10, y: 20))
        let controller = MacInputController(mouseEventPoster: poster)

        controller.handle(.mouseButton(MouseButtonCommand(button: .left, phase: .down)))
        poster.location = CGPoint(x: 10, y: 20)
        controller.handle(.mouseMove(PointerDelta(dx: 6, dy: -3)))
        poster.location = CGPoint(x: 16, y: 17)
        controller.handle(.mouseButton(MouseButtonCommand(button: .left, phase: .up)))

        XCTAssertEqual(
            poster.requests,
            [
                MouseEventRequest(type: .leftMouseDown, button: .left, location: CGPoint(x: 10, y: 20), clickCount: 1),
                MouseEventRequest(
                    type: .leftMouseDragged,
                    button: .left,
                    location: CGPoint(x: 16, y: 17),
                    clickCount: 1
                ),
                MouseEventRequest(type: .leftMouseUp, button: .left, location: CGPoint(x: 16, y: 17), clickCount: 1)
            ]
        )
    }

    func test_scrollPhasePostsContinuousTrackpadStyleScrollRequest() {
        let mousePoster = RecordingMouseEventPoster(location: CGPoint(x: 10, y: 20))
        let scrollPoster = RecordingScrollEventPoster()
        let controller = MacInputController(
            mouseEventPoster: mousePoster,
            scrollEventPoster: scrollPoster
        )

        controller.handle(.mouseScrollPhase(PointerDelta(dx: 4.4, dy: -8.6), .change))

        XCTAssertEqual(
            scrollPoster.requests,
            [ScrollEventRequest(dx: 4, dy: -9, phase: .change)]
        )
    }
}

private final class RecordingMouseEventPoster: MouseEventPosting {
    var location: CGPoint
    private(set) var requests: [MouseEventRequest] = []
    private(set) var warpPoints: [CGPoint] = []

    init(location: CGPoint) {
        self.location = location
    }

    func warp(to point: CGPoint) {
        warpPoints.append(point)
        location = point
    }

    func postMouse(_ request: MouseEventRequest) {
        requests.append(request)
        location = request.location
    }
}

private final class RecordingScrollEventPoster: ScrollEventPosting {
    private(set) var requests: [ScrollEventRequest] = []

    func postScroll(_ request: ScrollEventRequest) {
        requests.append(request)
    }
}
