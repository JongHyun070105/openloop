import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: sim-input tap x y | sim-input swipe x1 y1 x2 y2\n", stderr)
    exit(64)
}

let source = CGEventSource(stateID: .combinedSessionState)

func number(_ index: Int) -> CGFloat {
    guard CommandLine.arguments.indices.contains(index), let value = Double(CommandLine.arguments[index]) else {
        fputs("invalid coordinate\n", stderr)
        exit(64)
    }
    return CGFloat(value)
}

func event(_ type: CGEventType, at point: CGPoint) {
    guard let event = CGEvent(
        mouseEventSource: source,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: .left
    ) else {
        fputs("could not create mouse event\n", stderr)
        exit(70)
    }
    event.post(tap: .cghidEventTap)
}

switch CommandLine.arguments[1] {
case "tap":
    let point = CGPoint(x: number(2), y: number(3))
    event(.mouseMoved, at: point)
    usleep(20_000)
    event(.leftMouseDown, at: point)
    usleep(35_000)
    event(.leftMouseUp, at: point)
case "swipe":
    let start = CGPoint(x: number(2), y: number(3))
    let end = CGPoint(x: number(4), y: number(5))
    event(.mouseMoved, at: start)
    usleep(20_000)
    event(.leftMouseDown, at: start)
    for step in 1...12 {
        let progress = CGFloat(step) / 12
        let point = CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
        usleep(18_000)
        event(.leftMouseDragged, at: point)
    }
    usleep(35_000)
    event(.leftMouseUp, at: end)
default:
    fputs("unsupported input\n", stderr)
    exit(64)
}
