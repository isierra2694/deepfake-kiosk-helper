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
