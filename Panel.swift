import Cocoa

final class ControlWindow: NSWindow {
    let status = NSTextField(labelWithString: "")
    let display = NSTextField(labelWithString: "—")
    let timing = NSTextField(labelWithString: "—")
    let game = NSTextField(labelWithString: "")
    let mouse = NSPopUpButton()
    let wheelSpeed = NSPopUpButton()
    let speed = NSPopUpButton()
    let login = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    let loginSettings = NSButton()
    let pause = NSButton()
    let access = NSTextField(labelWithString: "")

    init(controller: App) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 570, height: 500),
                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        title = "GameMouseLock"
        isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView!.topAnchor, constant: 24)
        ])
        func button(_ title: String, _ action: Selector) -> NSButton {
            NSButton(title: title, target: controller, action: action)
        }
        func row(_ title: String, _ controls: NSView...) {
            let label = NSTextField(labelWithString: title)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 126).isActive = true
            let row = NSStackView(views: [label] + controls)
            row.spacing = 8
            stack.addArrangedSubview(row)
        }
        status.font = .systemFont(ofSize: 22, weight: .semibold)
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(status)
        row("Last locked display", display)
        timing.toolTip = "Time from the latest mouse movement in a batch to posting its pointer event. Excludes game and display latency."
        row("Last input to post", timing)
        row("Game", game)
        row("", button("Choose game…", #selector(App.choose)), button("Use League", #selector(App.resetGame)))
        mouse.target = controller
        mouse.action = #selector(App.selectMouse(_:))
        row("Gaming mouse", mouse)
        speed.target = controller
        speed.action = #selector(App.speed(_:))
        for value in [0.25, 0.5, 1, 1.5, 2] {
            speed.addItem(withTitle: String(value) + "×")
            speed.lastItem?.representedObject = value
        }
        row("Pointer speed", speed)
        wheelSpeed.target = controller
        wheelSpeed.action = #selector(App.changeWheelSpeed(_:))
        for value in WheelSpeed.choices {
            wheelSpeed.addItem(withTitle: String(value) + "×")
            wheelSpeed.lastItem?.tag = value
        }
        row("Scroll wheel speed", wheelSpeed)
        row("Permissions", access)
        login.target = controller
        login.action = #selector(App.toggleLogin(_:))
        loginSettings.title = "Approve in System Settings…"
        loginSettings.bezelStyle = .rounded
        loginSettings.target = controller
        loginSettings.action = #selector(App.openLoginSettings)
        row("Startup", login, loginSettings)
        pause.target = controller
        pause.action = #selector(App.toggle)
        pause.bezelStyle = .rounded
        row("", pause, button("Request permissions…", #selector(App.permissions)))
        center()
    }
}
