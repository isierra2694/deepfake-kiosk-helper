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

// Regression: touch drivers can report every tap with clickCount == 1.
// Repeat taps in the page, and on the other display, must still be suppressed.
var clicks = SingleClickPolicy(interval: 0.5)
expect(clicks.suppress(.down(0), at: middle, time: 1, clickCount: 1), false, "first click in page")
expect(clicks.suppress(.up(0), at: middle, time: 1.05, clickCount: 1), false, "first release in page")
expect(clicks.suppress(.down(0), at: CGPoint(x: middle.x + 12, y: middle.y), time: 1.2, clickCount: 1), true, "repeat tap with touch jitter and count 1")
expect(clicks.suppress(.drag(0), at: laptop, time: 1.22, clickCount: 1), true, "suppressed drag crossing displays")
expect(clicks.suppress(.up(0), at: laptop, time: 1.25, clickCount: 1), true, "suppressed release crossing displays")
expect(clicks.suppress(.down(0), at: middle, time: 1.4, clickCount: 1), true, "rapid third tap cannot restart sequence")
expect(clicks.suppress(.up(0), at: middle, time: 1.45, clickCount: 1), true, "third release suppressed")
expect(clicks.suppress(.down(0), at: middle, time: 2, clickCount: 1), false, "single click after interval")
expect(clicks.suppress(.drag(0), at: laptop, time: 2.1, clickCount: 1), false, "normal drag preserved")
expect(clicks.suppress(.up(0), at: laptop, time: 2.2, clickCount: 1), false, "normal drag release preserved")
expect(clicks.suppress(.down(0), at: laptop, time: 2.3, clickCount: 1), false, "rapid click on distant target allowed")
expect(clicks.suppress(.up(0), at: laptop, time: 2.35, clickCount: 1), false, "distant release allowed")
expect(clicks.suppress(.down(0), at: laptop, time: 2.4, clickCount: 0), true, "repeat on other display with missing count")
expect(clicks.suppress(.down(1), at: laptop, time: 2.41, clickCount: 1), false, "different button independent")
expect(clicks.suppress(.up(1), at: laptop, time: 2.42, clickCount: 1), false, "other button release paired")
expect(clicks.suppress(.up(0), at: laptop, time: 2.45, clickCount: 0), true, "repeat release with missing count")
expect(clicks.suppress(.down(2), at: laptop, time: 3, clickCount: 2), true, "native double click count respected")
expect(clicks.suppress(.up(2), at: laptop, time: 3.1, clickCount: 1), true, "release paired despite inconsistent count")
expect(clicks.suppress(.scroll, at: laptop, time: 3.2, clickCount: 0), false, "scroll preserved")

// Smart zoom is a gesture, independent of mouse click counts.
expect(ZoomGestureFilter.suppress(.smartMagnify), true, "smart zoom suppressed")
expect(ZoomGestureFilter.suppress(.magnify), true, "pinch zoom suppressed")
expect(ZoomGestureFilter.suppress(.scrollWheel), false, "ordinary scrolling preserved")
expect(ZoomGestureFilter.suppress(.swipe), false, "unrelated swipe preserved")
expect(ZoomGestureFilter.suppress(.gesture), false, "generic gestures not blanket blocked")
print("Passed \(checks) input policy checks.")
