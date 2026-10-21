import Foundation
import CoreGraphics

/// Geometry is in Quartz global coordinates: origin at the main display's top left,
/// measured in logical points. Other displays may have negative origins.
struct ProtectedRegion {
    var display: CGRect
    var top: CGFloat
    var bottom: CGFloat

    var interior: CGRect {
        CGRect(x: display.minX, y: display.minY + top,
               width: display.width, height: display.height - top - bottom)
    }

    func contains(_ point: CGPoint) -> Bool {
        display.contains(point) && !interior.contains(point)
    }

    func safePoint(for point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: min(max(point.y, interior.minY + 1), interior.maxY - 1))
    }
}

enum PointerInput {
    case move, scroll
    case down(Int), up(Int), drag(Int)
}

/// Some touch drivers label every tap as a single click. Detect nearby repeat
/// presses independently, and discard their entire press/drag/release sequence.
struct SingleClickPolicy {
    var interval: TimeInterval
    var radius: CGFloat = 32
    private var lastPress: [Int: (time: TimeInterval, point: CGPoint)] = [:]
    private var suppressedButtons = Set<Int>()

    init(interval: TimeInterval) { self.interval = interval }

    mutating func suppress(_ input: PointerInput, at point: CGPoint,
                           time: TimeInterval, clickCount: Int64) -> Bool {
        switch input {
        case .down(let button):
            let previous = lastPress[button]
            lastPress[button] = (time, point)
            let nearbyRepeat = previous.map {
                let elapsed = time - $0.time
                let dx = point.x - $0.point.x
                let dy = point.y - $0.point.y
                return elapsed >= 0 && elapsed <= interval && dx * dx + dy * dy <= radius * radius
            } ?? false
            if clickCount > 1 || nearbyRepeat {
                suppressedButtons.insert(button)
                return true
            }
            suppressedButtons.remove(button)
            return false
        case .up(let button):
            return suppressedButtons.remove(button) != nil
        case .drag(let button):
            return suppressedButtons.contains(button)
        case .move, .scroll:
            return false
        }
    }
}

enum EdgeDecision: Equatable {
    case pass
    case suppress(cursor: CGPoint?)
    case redirect(CGPoint)
}

/// Keeps complete button sequences paired. A touch begun in a blocked strip
/// cannot turn into a click when the finger subsequently moves into the page.
struct EdgePolicy {
    var region: ProtectedRegion
    private var suppressedButtons = Set<Int>()
    private var passedButtons = Set<Int>()

    mutating func decide(_ input: PointerInput, at point: CGPoint) -> EdgeDecision {
        let blocked = region.contains(point)
        let safe = blocked ? region.safePoint(for: point) : nil
        switch input {
        case .down(let button):
            if blocked {
                suppressedButtons.insert(button)
                passedButtons.remove(button)
                return .suppress(cursor: safe)
            }
            suppressedButtons.remove(button)
            passedButtons.insert(button)
            return .pass
        case .up(let button):
            if suppressedButtons.remove(button) != nil {
                return .suppress(cursor: safe)
            }
            // Deliver a release for a press that reached Chrome, even if the
            // finger ends in a blocked strip. Otherwise Chrome can stay dragging.
            if passedButtons.remove(button) != nil, let safe {
                return .redirect(safe)
            }
            return blocked ? .suppress(cursor: safe) : .pass
        case .drag(let button):
            if suppressedButtons.contains(button) { return .suppress(cursor: safe) }
            return safe.map(EdgeDecision.redirect) ?? .pass
        case .move:
            return safe.map(EdgeDecision.redirect) ?? .pass
        case .scroll:
            return blocked ? .suppress(cursor: safe) : .pass
        }
    }
}
