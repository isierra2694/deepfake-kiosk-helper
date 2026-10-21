import AppKit

enum ZoomGestureFilter {
    // Quartz transports AppKit magnification events as generic gesture events.
    // Decode the NSEvent type before filtering so unrelated gestures can pass.
    static let transportType = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue))!

    static func suppress(_ type: NSEvent.EventType) -> Bool {
        type == .smartMagnify
    }
}
