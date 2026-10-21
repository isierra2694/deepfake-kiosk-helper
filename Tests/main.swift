import Foundation
import CoreGraphics

var checks = 0
func expect(_ actual: EdgeDecision, _ expected: EdgeDecision, _ label: String) {
    checks += 1
    guard actual == expected else { fatalError("\(label): got \(actual), expected \(expected)") }
}

// A portrait touch display positioned left of and above the MacBook.
let region = ProtectedRegion(display: CGRect(x: -1080, y: -200, width: 1080, height: 1920),
                             top: 48, bottom: 80)
var policy = EdgePolicy(region: region)
let top = CGPoint(x: -500, y: -199)
let bottom = CGPoint(x: -500, y: 1719)
let middle = CGPoint(x: -500, y: 300)
let laptop = CGPoint(x: 500, y: 10)
expect(policy.decide(.down(0), at: top), .suppress(cursor: CGPoint(x: -500, y: -151)), "top tap")
expect(policy.decide(.drag(0), at: middle), .suppress(cursor: nil), "blocked drag entering page")
expect(policy.decide(.up(0), at: middle), .suppress(cursor: nil), "blocked release entering page")
expect(policy.decide(.down(0), at: middle), .pass, "page tap")
expect(policy.decide(.drag(0), at: bottom), .redirect(CGPoint(x: -500, y: 1639)), "page drag to edge")
expect(policy.decide(.up(0), at: bottom), .redirect(CGPoint(x: -500, y: 1639)), "paired release")
expect(policy.decide(.move, at: top), .redirect(CGPoint(x: -500, y: -151)), "hover reveal")
expect(policy.decide(.move, at: laptop), .pass, "MacBook movement")
expect(policy.decide(.down(1), at: laptop), .pass, "MacBook right click")
expect(policy.decide(.up(1), at: laptop), .pass, "MacBook right release")
expect(policy.decide(.scroll, at: bottom), .suppress(cursor: CGPoint(x: -500, y: 1639)), "edge scrolling")
expect(policy.decide(.scroll, at: middle), .pass, "page scrolling")
expect(policy.decide(.down(1), at: bottom), .suppress(cursor: CGPoint(x: -500, y: 1639)), "edge right click")
expect(policy.decide(.up(1), at: laptop), .suppress(cursor: nil), "blocked sequence crossing displays")
expect(policy.decide(.down(0), at: CGPoint(x: -500, y: -152)), .pass, "exact interior top")
expect(policy.decide(.up(0), at: middle), .pass, "normal release")
expect(policy.decide(.down(0), at: CGPoint(x: -500, y: 1640)), .suppress(cursor: CGPoint(x: -500, y: 1639)), "exact bottom boundary")
expect(policy.decide(.up(0), at: bottom), .suppress(cursor: CGPoint(x: -500, y: 1639)), "blocked release")

var unguarded = EdgePolicy(region: ProtectedRegion(display: region.display, top: 0, bottom: 0))
expect(unguarded.decide(.move, at: top), .pass, "disabled top")
expect(unguarded.decide(.move, at: bottom), .pass, "disabled bottom")
func expect(_ actual: Bool, _ expected: Bool, _ label: String) {
    checks += 1
    guard actual == expected else { fatalError("\(label): got \(actual), expected \(expected)") }
}

// Repeated presses must all pass in the page and on the operator's display.
var repeatPolicy = EdgePolicy(region: region)
for point in [middle, laptop] {
    for button in [0, 1, 2] {
        for click in 1...3 {
            expect(repeatPolicy.decide(.down(button), at: point), .pass, "press \(click), button \(button)")
            expect(repeatPolicy.decide(.up(button), at: point), .pass, "release \(click), button \(button)")
        }
    }
}

// Smart zoom is a gesture, independent of mouse click counts.
expect(ZoomGestureFilter.suppress(.smartMagnify), true, "smart zoom suppressed")
expect(ZoomGestureFilter.suppress(.magnify), false, "pinch zoom allowed")
expect(ZoomGestureFilter.suppress(.leftMouseDown), false, "mouse presses allowed")
expect(ZoomGestureFilter.suppress(.leftMouseUp), false, "mouse releases allowed")
expect(ZoomGestureFilter.suppress(.scrollWheel), false, "ordinary scrolling preserved")
expect(ZoomGestureFilter.suppress(.swipe), false, "unrelated swipe preserved")
expect(ZoomGestureFilter.suppress(.gesture), false, "generic gestures not blanket blocked")
print("Passed \(checks) input policy checks.")
