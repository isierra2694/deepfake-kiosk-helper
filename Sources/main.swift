import AppKit
import ApplicationServices
import Carbon
import ColorSync

struct DisplayChoice {
    let id: CGDirectDisplayID
    let uuid: String
    let screen: NSScreen
    var bounds: CGRect { CGDisplayBounds(id) }
    var isBuiltIn: Bool { CGDisplayIsBuiltin(id) != 0 }
    var isMirrored: Bool { CGDisplayIsInMirrorSet(id) != 0 }
    var title: String {
        let kind = isBuiltIn ? "MacBook / built-in" : "External"
        return "\(screen.localizedName) — \(kind) — \(Int(bounds.width)) × \(Int(bounds.height)) pt"
    }

    static func connected() -> [DisplayChoice] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let unmanaged = CGDisplayCreateUUIDFromDisplayID(number.uint32Value) else { return nil }
            let uuid = CFUUIDCreateString(nil, unmanaged.takeRetainedValue()) as String
            return DisplayChoice(id: number.uint32Value, uuid: uuid, screen: screen)
        }
    }
}

final class EdgeGuard {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var policy: EdgePolicy?
    private var suppressedMultiClickButtons = Set<Int>()
    private(set) var intercepted = 0
    private(set) var recoveryCount = 0
    private(set) var cursorFailed = false
    var isRunning: Bool { tap != nil }
    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start(region: ProtectedRegion) -> Bool {
        stop()
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<EdgeGuard>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        self.source = source
        policy = EdgePolicy(region: region)
        intercepted = 0
        recoveryCount = 0
        cursorFailed = false
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        policy = nil
        suppressedMultiClickButtons.removeAll()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true); recoveryCount += 1 }
            return Unmanaged.passUnretained(event)
        }
        guard policy != nil else { return Unmanaged.passUnretained(event) }
        let button: Int?
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: button = 0
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: button = 1
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        default: button = nil
        }
        if let button {
            switch type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                if event.getIntegerValueField(.mouseEventClickState) > 1 {
                    suppressedMultiClickButtons.insert(button)
                    intercepted += 1
                    return nil
                }
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                if suppressedMultiClickButtons.remove(button) != nil {
                    intercepted += 1
                    return nil
                }
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                if suppressedMultiClickButtons.contains(button) {
                    intercepted += 1
                    return nil
                }
            default: break
            }
        }
        let input: PointerInput
        switch type {
        case .leftMouseDown: input = .down(0)
        case .rightMouseDown: input = .down(1)
        case .otherMouseDown: input = .down(Int(event.getIntegerValueField(.mouseEventButtonNumber)))
        case .leftMouseUp: input = .up(0)
        case .rightMouseUp: input = .up(1)
        case .otherMouseUp: input = .up(Int(event.getIntegerValueField(.mouseEventButtonNumber)))
        case .leftMouseDragged: input = .drag(0)
        case .rightMouseDragged: input = .drag(1)
        case .otherMouseDragged: input = .drag(Int(event.getIntegerValueField(.mouseEventButtonNumber)))
        case .scrollWheel: input = .scroll
        case .mouseMoved: input = .move
        default: return Unmanaged.passUnretained(event)
        }
        // Copy back mutated gesture state without doing UI work in the callback.
        let decision = policy!.decide(input, at: event.location)
        switch decision {
        case .pass: return Unmanaged.passUnretained(event)
        case .suppress(let cursor):
            intercepted += 1
            if let cursor, CGWarpMouseCursorPosition(cursor) != .success { cursorFailed = true }
            return nil
        case .redirect(let point):
            intercepted += 1
            event.location = point
            if CGWarpMouseCursorPosition(point) != .success { cursorFailed = true }
            return Unmanaged.passUnretained(event)
        }
    }
}

final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let guardEngine = EdgeGuard()
    private let defaults = UserDefaults.standard
    private var displays: [DisplayChoice] = []
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private let displayPicker = NSPopUpButton()
    private let topField = NSTextField(string: "48")
    private let bottomField = NSTextField(string: "80")
    private let stateLabel = NSTextField(wrappingLabelWithString: "Paused — touch input is unchanged.")
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let toggleButton = NSButton(title: "Enable protection", target: nil, action: nil)
    private var timer: Timer?
    private var panels: [NSPanel] = []
    private var previewTimer: Timer?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var hotKeyReady = false
    private var activeUUID: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        installEmergencyShortcut()
        refreshDisplays()
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshStatus() }
        showSettings()
        refreshStatus()
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        let pauseItem = appMenu.addItem(withTitle: "Pause Protection", action: #selector(emergencyPause), keyEquivalent: "k")
        pauseItem.target = self
        pauseItem.keyEquivalentModifierMask = [.control, .option, .command]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Kiosk Edge Guard", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Guard: Paused"
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "Pause Protection (⌃⌥⌘K)", action: #selector(emergencyPause), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "").target = self
        statusItem.menu = statusMenu
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 610),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Kiosk Edge Guard"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26)
        ])
        let heading = NSTextField(labelWithString: "Keep the experience within reach.")
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        root.addArrangedSubview(heading)
        root.addArrangedSubview(wrapped("Allow single clicks only across all displays and block taps and pointer movement in the top and bottom strips of the selected display. Chrome and the rest of the screen stay interactive."))
        let label = NSTextField(labelWithString: "Touch display")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(label)
        displayPicker.target = self
        displayPicker.action = #selector(selectionChanged)
        root.addArrangedSubview(displayPicker)
        displayPicker.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let displayButtons = NSStackView(views: [button("Identify display", #selector(identify)), button("Refresh displays", #selector(manualRefresh))])
        displayButtons.spacing = 10
        root.addArrangedSubview(displayButtons)
        topField.stringValue = defaults.string(forKey: "topPoints") ?? "48"
        bottomField.stringValue = defaults.string(forKey: "bottomPoints") ?? "80"
        for field in [topField, bottomField] { field.widthAnchor.constraint(equalToConstant: 64).isActive = true }
        let sizes = NSStackView(views: [NSTextField(labelWithString: "Top:"), topField,
            NSTextField(labelWithString: "pt    Bottom:"), bottomField, NSTextField(labelWithString: "pt")])
        sizes.spacing = 8
        root.addArrangedSubview(sizes)
        root.addArrangedSubview(wrapped("Start with 48 pt at the top and 80 pt at the bottom. Increase a strip if the touch driver reaches past it. Set either to 0 to leave that edge available."))
        root.addArrangedSubview(button("Preview blocked strips (5 seconds)", #selector(preview)))
        permissionLabel.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(permissionLabel)
        root.addArrangedSubview(button("Open Accessibility settings…", #selector(openPermissions)))
        stateLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        root.addArrangedSubview(stateLabel)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(countLabel)
        toggleButton.target = self
        toggleButton.action = #selector(toggle)
        toggleButton.bezelStyle = .rounded
        root.addArrangedSubview(toggleButton)
        root.addArrangedSubview(wrapped("Emergency pause: Control + Option + Command + K\nProtection starts paused. Pauses on sleep, user switching, or display changes."))
        // Keep explanatory labels constrained so they wrap rather than widen the window.
        for view in root.arrangedSubviews where view is NSTextField {
            view.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor).isActive = true
        }
        window.setContentSize(NSSize(width: 640, height: max(610, root.fittingSize.height + 52)))
        if let screen = NSScreen.screens.first(where: { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(n.uint32Value) != 0
        }) {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                          y: screen.visibleFrame.midY - window.frame.height / 2))
        } else { window.center() }
    }

    private func wrapped(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = 584
        return label
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private var selected: DisplayChoice? {
        let index = displayPicker.indexOfSelectedItem
        return displays.indices.contains(index) ? displays[index] : nil
    }

    private func refreshDisplays() {
        let saved = selected?.uuid ?? defaults.string(forKey: "displayUUID")
        displays = DisplayChoice.connected()
        displayPicker.removeAllItems()
        displayPicker.addItems(withTitles: displays.map(\.title))
        displayPicker.select(nil)
        if let saved {
            if let index = displays.firstIndex(where: { $0.uuid == saved }) { displayPicker.selectItem(at: index) }
        } else {
            let external = displays.indices.filter { !displays[$0].isBuiltIn && !displays[$0].isMirrored }
            if external.count == 1 { displayPicker.selectItem(at: external[0]) }
        }
        if selected == nil { stateLabel.stringValue = "Paused — choose a connected touch display." }
    }

    private func validatedRegion() -> ProtectedRegion? {
        guard let display = selected else { message("Choose the touch display first."); return nil }
        guard !display.isMirrored else { message("Use an extended desktop. Mirrored displays share a coordinate space and cannot be protected independently."); return nil }
        guard let top = Double(topField.stringValue), let bottom = Double(bottomField.stringValue),
              top.isFinite, bottom.isFinite, top >= 0, bottom >= 0,
              top + bottom >= 1, top + bottom < display.bounds.height - 40 else {
            message("Enter nonnegative strip sizes in points. Leave at least 40 pt for the experience, and protect at least one edge.")
            return nil
        }
        return ProtectedRegion(display: display.bounds, top: top, bottom: bottom)
    }

    @objc private func toggle() {
        if guardEngine.isRunning { pause("Paused — touch input is unchanged."); return }
        guard let region = validatedRegion(), let display = selected else { return }
        guard hotKeyReady else { message("The emergency shortcut could not be registered. Quit another app using Control + Option + Command + K, then relaunch Edge Guard."); return }
        guard AXIsProcessTrusted() else { openPermissions(); return }
        clearPanels()
        guard guardEngine.start(region: region) else {
            guardEngine.stop()
            message("macOS did not allow input filtering. Enable Kiosk Edge Guard in Accessibility settings, quit and reopen it, then try again. If macOS also requests Input Monitoring, allow it there.")
            return
        }
        activeUUID = display.uuid
        defaults.set(display.uuid, forKey: "displayUUID")
        defaults.set(topField.stringValue, forKey: "topPoints")
        defaults.set(bottomField.stringValue, forKey: "bottomPoints")
        stateLabel.stringValue = "Protecting \(display.screen.localizedName) — top \(topField.stringValue) pt / bottom \(bottomField.stringValue) pt"
        setEditingEnabled(false)
        refreshStatus()
    }

    private func pause(_ reason: String) {
        guardEngine.stop()
        activeUUID = nil
        stateLabel.stringValue = reason
        clearPanels()
        setEditingEnabled(true)
        refreshStatus()
    }

    private func setEditingEnabled(_ enabled: Bool) {
        displayPicker.isEnabled = enabled
        topField.isEnabled = enabled
        bottomField.isEnabled = enabled
        toggleButton.title = enabled ? "Enable protection" : "Pause protection"
    }

    private func refreshStatus() {
        if guardEngine.isRunning {
            if !AXIsProcessTrusted() || !guardEngine.isEnabled || guardEngine.cursorFailed {
                guardEngine.stop()
                activeUUID = nil
                stateLabel.stringValue = "Protection stopped — input control was interrupted. Check permissions and enable again."
                setEditingEnabled(true)
                showSettings()
                NSSound.beep()
            }
        }
        permissionLabel.stringValue = AXIsProcessTrusted() ? "Accessibility permission: granted" : "Accessibility permission: needed to block edge input"
        countLabel.stringValue = "Intercepted events: \(guardEngine.intercepted)    Filter recoveries: \(guardEngine.recoveryCount)"
        statusItem.button?.title = guardEngine.isRunning ? "Guard: ON" : "Guard: Paused"
        statusItem.button?.toolTip = stateLabel.stringValue
    }

    @objc private func selectionChanged() {
        clearPanels()
        if let selected { defaults.set(selected.uuid, forKey: "displayUUID") }
    }

    @objc private func manualRefresh() {
        if guardEngine.isRunning { pause("Paused — displays refreshed. Enable protection when ready.") }
        clearPanels()
        refreshDisplays()
    }

    @objc private func displayChanged() {
        if guardEngine.isRunning { pause("Paused — display layout changed. Check the selected display and enable again.") }
        clearPanels()
        refreshDisplays()
    }

    @objc private func willSleep() {
        if guardEngine.isRunning { pause("Paused — Mac slept or the user session changed. Enable again before use.") }
    }

    @objc func emergencyPause() {
        pause("Paused with emergency stop — touch input is unchanged.")
        showSettings()
    }

    @objc private func showSettings() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func identify() {
        guard let display = selected else { message("Choose a display first."); return }
        clearPanels()
        let frame = NSRect(x: display.screen.frame.midX - 220, y: display.screen.frame.midY - 60, width: 440, height: 120)
        showPanel(frame: frame, text: display.screen.localizedName + "\nSelected touch display", color: .systemBlue)
        scheduleClear(after: 3)
    }

    @objc private func preview() {
        guard let region = validatedRegion(), let display = selected else { return }
        clearPanels()
        let frame = display.screen.frame
        if region.top > 0 {
            showPanel(frame: NSRect(x: frame.minX, y: frame.maxY - region.top, width: frame.width, height: region.top), text: "TOP — blocked strip", color: .systemOrange)
        }
        if region.bottom > 0 {
            showPanel(frame: NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: region.bottom), text: "BOTTOM — blocked strip", color: .systemOrange)
        }
        scheduleClear(after: 5)
    }

    private func showPanel(frame: NSRect, text: String, color: NSColor) {
        let panel = PreviewPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = color.withAlphaComponent(0.8)
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        let label = NSTextField(labelWithString: text)
        label.textColor = .white
        label.alignment = .center
        label.font = .systemFont(ofSize: 16, weight: .bold)
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: panel.contentView!.centerXAnchor), label.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor)])
        panel.orderFrontRegardless()
        panels.append(panel)
    }

    private func scheduleClear(after seconds: TimeInterval) {
        previewTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.clearPanels() }
    }

    private func clearPanels() {
        previewTimer?.invalidate()
        previewTimer = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private func message(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Kiosk Edge Guard"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func installEmergencyShortcut() {
        let callback: EventHandlerUPP = { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().emergencyPause()
            return noErr
        }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerResult = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &event,
            Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        let id = EventHotKeyID(signature: 0x4B454447, id: 1)
        let registration = RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey | cmdKey), id,
            GetApplicationEventTarget(), 0, &hotKey)
        hotKeyReady = handlerResult == noErr && registration == noErr
        if !hotKeyReady {
            stateLabel.stringValue = "Paused — emergency shortcut unavailable. Protection cannot start until the shortcut is available."
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guardEngine.stop()
        clearPanels()
        timer?.invalidate()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
