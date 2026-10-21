# Kiosk Edge Guard

A small native macOS utility for an event kiosk: keep a local Chrome experience usable on an external touch display while blocking its top and bottom strips and ignoring multi-click sequences. The MacBook can remain open and its display remains available to the operator.

This is a **hardware-validation prototype**. While protection is enabled, it filters mouse, drag, and scroll events delivered through a Quartz session event tap across all displays. The first click in a sequence is allowed; subsequent clicks reported by macOS as part of a multi-click sequence are suppressed. A touch driver that delivers taps as mouse input should be covered. Drivers that inject events farther downstream, native gestures, and system behavior outside the event stream require testing on the actual kiosk. A successful build and the policy tests do not prove that a particular touch display cannot reveal the Dock or menu bar.

## Run

1. Open `build/Kiosk Edge Guard.app`. On the event Mac, put the app in its final location before granting permissions.
2. Open **System Settings → Privacy & Security → Accessibility**, enable **Kiosk Edge Guard**, and quit and reopen the app if needed. The app includes a button that opens this pane. If macOS also asks for Input Monitoring, grant it there. No screen recording permission is used.
3. Use **extended displays**, not mirroring. Choose the external touch display. Use **Identify display** to confirm the target.
4. Start with **Top: 48 pt** and **Bottom: 80 pt**. Preview the strips and adjust their sizes for the touch calibration and display scaling. The strips span the entire width. `0` leaves an edge unprotected. The Dock should be at the bottom for this configuration.
5. Launch the existing local web experience in Chrome and put it on the external display, using its existing kiosk/full-screen setup. Enabling this utility does not launch or reconfigure Chrome.
6. Click **Enable protection**, then return focus to Chrome. Closing the settings window leaves protection running. The menu bar status item says **Guard: ON** or **Guard: Paused**.

**Emergency pause: Control + Option + Command + K**, using the MacBook keyboard. You can also pause or quit from the app's menu or status item on the MacBook display. This shortcut only pauses; it never enables protection.

The app starts paused on every launch. It remembers the display UUID and strip sizes, but never silently picks a replacement for a disconnected saved display. It pauses on display configuration changes, sleep, or user-session deactivation. Re-enable after checking the setup. It does not modify Dock, menu-bar, Chrome, login, or power settings. Keep the event Mac awake using your existing event setup.

## Verify on the event hardware

Do this with the exact Mac, touch driver, display orientation, scaling, and Chrome configuration used at the event:

- Confirm a mouse on the MacBook can use its menu bar and Dock with protection on.
- Tap and hold across the whole top strip, including corners. Repeat across the bottom strip. Try rapid taps and press-and-drag gestures. Neither strip should let a visitor operate macOS controls.
- Watch the intercepted-event counter on the MacBook. It should increase when touching the guarded strips. A flat counter indicates that the touch events are not reaching this filter or are mapped to another display.
- Touch buttons, scroll, and drag within the web experience. Slide a touch from the page into a strip and release; Chrome must not remain dragging. Start a touch in a strip, slide into the page, and release; it must not activate page controls.
- If the Dock or menu bar still appears, verify it cannot be operated. Increase the strip to cover the entire visible system control region and repeat. A bottom strip sized only for the reveal edge does not cover a Dock extending higher into the display.
- Test the emergency shortcut with Chrome active. Confirm quitting the utility immediately restores ordinary input.
- Confirm a rapid second click does not trigger double-click behavior on either display while protection is enabled. With protection paused, normal multi-click input is restored.
- Test unplug/replug, rotation or scaling changes, sleep/wake, and restarting the utility. Check that it pauses visibly and that deliberate re-enabling protects the correct monitor.
- Test any multi-touch gestures exposed by the driver. These are not universally represented as mouse events and are outside the prototype's guarantee.

Blocking a strip also blocks web content beneath it; keep important page controls inside the remaining area. The utility may move the cursor inward when a touch lands in a strip. It cannot provide per-display isolation for keyboard shortcuts or lock down the entire macOS session. A vertically stacked display boundary may be harder to cross with a mouse because guarded bands exclude pointer positions there; use a side-by-side arrangement where practical.

## Build and test

Requires macOS with Apple Command Line Tools (Swift compiler); no downloaded dependencies or Xcode project required. The deployment target is macOS 13. Build scripts create their module cache within `build/`.

```sh
zsh build.sh
zsh test.sh
```

The default build uses the current Mac's architecture. For a universal app usable on Apple silicon and Intel:

```sh
ARCHS="arm64 x86_64" zsh build.sh
```

The build applies a local ad-hoc signature. For a stable signing identity, set `SIGNING_IDENTITY` to your installed signing certificate when building. Rebuilding an ad-hoc signed binary may require reauthorizing Accessibility. This project does not notarize or install the app.

## Implementation

- `Sources/EdgePolicy.swift`: point-based Quartz geometry and gesture-sequence policy. Handles negative display origins and preserves releases for clicks begun in the page.
- `Sources/main.swift`: native AppKit settings, persistent display selection, previews, a session event filter for edge protection and single-click-only input, permission checks, and a Carbon emergency hotkey. Ordinary keystrokes are not monitored.
- `Tests/main.swift`: executable policy checks covering edge taps, boundary coordinates, drag/release pairing, blocked gestures crossing displays, and unaffected MacBook events.

Relevant Apple APIs: [event tap locations](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation), [event filtering](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback), [display bounds](https://developer.apple.com/documentation/coregraphics/cgdisplaybounds(_:)), and [cursor movement](https://developer.apple.com/documentation/coregraphics/cgwarpmousecursorposition(_:)).
