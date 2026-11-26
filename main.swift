import Cocoa
import ServiceManagement
import IOKit.hid

let league = "com.riotgames.LeagueofLegends.GameClient"

func gameDisplay(pid: pid_t) -> CGRect {
    let main = CGDisplayBounds(CGMainDisplayID())
    var displays = [CGDirectDisplayID](repeating: 0, count: max(1, NSScreen.screens.count))
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success,
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return main }
    let bounds = displays.prefix(Int(count)).map(CGDisplayBounds)
    var best = main
    var area: CGFloat = 0
    for window in windows where window[kCGWindowOwnerPID as String] as? Int32 == pid &&
        window[kCGWindowLayer as String] as? Int == 0 {
        guard let fields = window[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: fields) else { continue }
        for display in bounds {
            let overlap = frame.intersection(display)
            if !overlap.isNull, overlap.width * overlap.height > area {
                area = overlap.width * overlap.height
                best = display
            }
        }
    }
    return best
}

final class App: NSObject, NSApplicationDelegate {
    let capture = Capture()
    let prefs = UserDefaults.standard
    var window: ControlWindow!
    var state = "Waiting for game"
    var selected = (UserDefaults.standard.object(forKey: "mouseRegistryID") as? NSNumber)?.uint64Value
    var failed = false
    var panelOpen = false
    var devices = [Mouse]()
    var target: String { prefs.string(forKey: "game") ?? league }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let mainMenu = NSMenu()
        let appItem = mainMenu.addItem(withTitle: "GameMouseLock", action: nil, keyEquivalent: "")
        let commands = NSMenu()
        commands.addItem(withTitle: "Quit GameMouseLock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = commands
        NSApp.mainMenu = mainMenu
        window = ControlWindow(controller: self)
        let savedWheelSpeed = prefs.integer(forKey: "wheelSpeed")
        let wheelSpeed = WheelSpeed.choices.contains(savedWheelSpeed) ? savedWheelSpeed : WheelSpeed.initial
        capture.setWheelSpeed(wheelSpeed)
        window.wheelSpeed.selectItem(withTag: wheelSpeed)
        if CommandLine.arguments.contains("--check-window") {
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        updateLoginControl()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(focus), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(sleepNow), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(focus), name: NSWorkspace.didWakeNotification, object: nil)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
        if CommandLine.arguments.contains("--check-window") {
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(window.isVisible && window.mouse.numberOfItems > 0)
            precondition(window.status.stringValue == "Paused" || window.status.stringValue == "Waiting for game")
            precondition(window.speed.numberOfItems == 5)
            let bottom = window.pause.convert(window.pause.bounds, to: window.contentView)
            precondition(window.contentView!.bounds.contains(bottom))
            print("Passed window, device selector, status, input worker and layout checks.")
            NSApp.terminate(nil)
        } else if !CGPreflightPostEventAccess() || !CGPreflightListenEventAccess() { permissions() }
    }
    func applicationWillTerminate(_ notification: Notification) { capture.stop() }
    @objc func sleepNow() { capture.stop() }
    @objc func focus() { failed = false; refresh() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func refresh() {
        guard window != nil else { return }
        defer { render() }

        guard !CommandLine.arguments.contains("--check-window"), !panelOpen, !prefs.bool(forKey: "paused"),
              let game = NSWorkspace.shared.frontmostApplication, game.bundleIdentifier == target else {
            capture.stop()
            failed = false
            state = prefs.bool(forKey: "paused") ? "Paused" : "Waiting for game"

            return
        }
        let bounds = gameDisplay(pid: game.processIdentifier)
        guard bounds.width >= 1, bounds.height >= 1 else { capture.stop(); return }
        if capture.mouse == nil {
            guard !failed else { return }
            guard CGPreflightPostEventAccess(), CGPreflightListenEventAccess() else {
                state = "Allow Accessibility and Input Monitoring"
                return
            }
            devices = Mouse.available()
            guard let mouse = devices.first(where: { $0.id == selected }) ?? (selected == nil && devices.count == 1 ? devices[0] : nil) else {
                state = devices.isEmpty ? "Connect an external mouse" : "Select your gaming mouse"
                return
            }
            capture.gain = prefs.object(forKey: "gain") as? Double ?? 1
            let error = capture.begin(mouse, in: bounds)
            guard error == 0 else {
                failed = true
                state = "Mouse capture failed (" + String(error) + "). Check permissions and refocus game."
                return
            }
        } else { capture.resize(bounds) }
        state = "Cursor locked"
        let screen = NSScreen.screens.first {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayBounds(number.uint32Value) == bounds
        }
        window.display.stringValue = (screen?.localizedName ?? "Display") + " · " + String(Int(bounds.width)) + " × " + String(Int(bounds.height)) + " pt"
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if window != nil { updateLoginControl() }
    }

    private func updateLoginControl() {
        let status = SMAppService.mainApp.status
        window.login.state = status == .enabled || status == .requiresApproval ? .on : .off
        window.loginSettings.isHidden = status != .requiresApproval
    }

    @objc func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc func toggleLogin(_ button: NSButton) {
        do {
            if button.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Start at login"
            alert.informativeText = error.localizedDescription + "\nTry opening your installed copy from Applications."
            alert.beginSheetModal(for: window)
        }
        updateLoginControl()
    }

    @objc func permissions() {
        if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
    }
    func render() {
        window.status.stringValue = state
        window.status.textColor = capture.mouse == nil ? .labelColor : .systemGreen
        window.timing.stringValue = capture.timing
        window.game.stringValue = prefs.string(forKey: "name") ?? "League of Legends"
        window.pause.title = prefs.bool(forKey: "paused") ? "Resume" : "Pause"
        let post = CGPreflightPostEventAccess(), listen = CGPreflightListenEventAccess()
        window.access.stringValue = post && listen ? "Granted" : [post ? nil : "Accessibility needed", listen ? nil : "Input Monitoring needed"].compactMap { $0 }.joined(separator: " · ")
        if capture.mouse == nil { devices = Mouse.available() }
        let ids = devices.map { $0.id }
        let shown = window.mouse.itemArray.compactMap { ($0.representedObject as? NSNumber)?.uint64Value }
        if shown != ids || window.mouse.numberOfItems == 0 {
            window.mouse.removeAllItems()
            window.mouse.addItem(withTitle: devices.isEmpty ? "No external mouse" : "Select a mouse…")
            for device in devices {
                window.mouse.addItem(withTitle: device.name)
                window.mouse.lastItem?.representedObject = NSNumber(value: device.id)
            }
        }
        let index = ids.firstIndex { $0 == selected }
        window.mouse.selectItem(at: index.map { $0 + 1 } ?? (selected == nil && ids.count == 1 ? 1 : 0))
        let gain = prefs.object(forKey: "gain") as? Double ?? 1
        window.speed.selectItem(withTitle: String(gain) + "×")
    }
    @objc func changeWheelSpeed(_ popup: NSPopUpButton) {
        let value = popup.selectedTag()
        guard WheelSpeed.choices.contains(value) else { return }
        prefs.set(value, forKey: "wheelSpeed")
        capture.setWheelSpeed(value)
    }

    @objc func speed(_ popup: NSPopUpButton) {
        guard let sender = popup.selectedItem else { return }
        guard let gain = sender.representedObject as? Double else { return }
        prefs.set(gain, forKey: "gain")
        capture.gain = gain
    }
    @objc func selectMouse(_ popup: NSPopUpButton) {
        guard let sender = popup.selectedItem else { return }
        capture.stop()
        selected = (sender.representedObject as? NSNumber)?.uint64Value
        prefs.set(sender.representedObject, forKey: "mouseRegistryID")
        focus()
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggle() { prefs.set(!prefs.bool(forKey: "paused"), forKey: "paused"); focus() }
    @objc func resetGame() {
        prefs.removeObject(forKey: "game")
        prefs.removeObject(forKey: "name")
        focus()
    }
    @objc func choose() {
        panelOpen = true
        capture.stop()
        defer { panelOpen = false; focus() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
            prefs.set(id, forKey: "game")
            prefs.set(url.deletingPathExtension().lastPathComponent, forKey: "name")
        }
    }
}

if CommandLine.arguments.contains("--test") {
    for value in WheelSpeed.choices {
        precondition(WheelSpeed.lines(1, multiplier: value) == Int32(value))
        precondition(WheelSpeed.lines(-3, multiplier: value) == -3 * Int32(value))
        precondition(WheelSpeed.lines(Int.max, multiplier: value) == Int32.max)
    }
    let workerCheck = Capture()
    workerCheck.gain = 1.5
    precondition(workerCheck.gain == 1.5 && workerCheck.mouse == nil)
    workerCheck.stop()
    for hz in [250, 2000, 8000] {
        for origin in [CGPoint.zero, CGPoint(x: -2560, y: -400), CGPoint(x: 150, y: 1440)] {
            let rect = CGRect(origin: origin, size: CGSize(width: 2560, height: 1440))
            var p = origin
            for i in 0..<(hz * 4) {
                p = bounded(CGPoint(x: p.x + (i % 13 < 6 ? -4800 : 4800),
                                    y: p.y + (i % 11 < 5 ? -3600 : 3600)), in: rect)
                precondition(rect.contains(p))
            }
            let corner = bounded(CGPoint(x: rect.maxX + 1, y: rect.minY - 1), in: rect)
            precondition(corner == CGPoint(x: rect.maxX - 1, y: rect.minY))
        }
    }
    print("Passed boundary checks. External mouse interfaces: " + Mouse.available().map { $0.name }.joined(separator: ", "))
} else {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.run()
}
