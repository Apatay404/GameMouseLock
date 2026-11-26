import Cocoa
import IOKit.hid

func bounded(_ point: CGPoint, in rect: CGRect) -> CGPoint {
    CGPoint(x: min(max(point.x, rect.minX), rect.maxX - 1),
            y: min(max(point.y, rect.minY), rect.maxY - 1))
}

struct Mouse {
    let name: String
    let id: UInt64

    static func available() -> [Mouse] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == 0 else { return [] }
        defer { IOObjectRelease(iterator) }
        var result = [Mouse]()
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue()
            }
            guard property(kIOHIDPrimaryUsagePageKey) as? Int == 1,
                  property(kIOHIDPrimaryUsageKey) as? Int == 2,
                  let transport = property(kIOHIDTransportKey) as? String,
                  ["USB", "Bluetooth", "Bluetooth Low Energy"].contains(transport),
                  property(kIOHIDBuiltInKey) as? Bool != true else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == 0 else { continue }
            let name = property(kIOHIDProductKey) as? String ?? transport + " mouse"
            result.append(Mouse(name: name, id: id))
        }
        return result.sorted { $0.id < $1.id }
    }
}

// Own all HID callbacks, the current pointer position and the output timer on one thread.
private final class InputLoop {
    private let ready = DispatchSemaphore(value: 0)
    private var loop: CFRunLoop!
    init() {
        let thread = Thread { [self] in
            loop = CFRunLoopGetCurrent()
            let port = NSMachPort()
            RunLoop.current.add(port, forMode: .default)
            ready.signal()
            withExtendedLifetime(port) { CFRunLoopRun() }
        }
        thread.name = "GameMouseLock input"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }
    func sync<T>(_ work: @escaping () -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        var result: T!
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            result = work()
            done.signal()
        }
        CFRunLoopWakeUp(loop)
        done.wait()
        return result
    }
}

enum WheelSpeed {
    static let choices = [1, 2, 3, 4, 8, 16]
    static let initial = 8

    static func lines(_ delta: Int, multiplier: Int) -> Int32 {
        Int32(clamping: Int64(Int32(clamping: delta)) * Int64(multiplier))
    }
}

final class Capture {
    private let worker = InputLoop()
    private let engine = InputEngine()
    var mouse: Mouse? { worker.sync { self.engine.mouse } }
    var gain: CGFloat {
        get { worker.sync { self.engine.gain } }
        set { worker.sync { self.engine.gain = newValue } }
    }
    func setWheelSpeed(_ multiplier: Int) {
        worker.sync { self.engine.wheelSpeed = multiplier }
    }
    var timing: String { worker.sync { self.engine.timing } }
    func begin(_ mouse: Mouse, in rect: CGRect) -> IOReturn {
        worker.sync { self.engine.begin(mouse, in: rect) }
    }
    func resize(_ bounds: CGRect) { worker.sync { self.engine.resize(bounds) } }
    func stop() { worker.sync { self.engine.stop() } }
}

private final class InputEngine {
    private var source: CGEventSource?
    private var device: IOHIDDevice?
    private(set) var mouse: Mouse?
    private var rect = CGRect.zero
    private var position = CGPoint.zero
    private var sent = CGPoint.zero
    private var held = [UInt32]()
    private var timer: Timer?
    var wheelSpeed = WheelSpeed.initial
    var gain: CGFloat = 1
    private var activity: NSObjectProtocol?
    private var newestInput: UInt64 = 0
    private var lastPostDelay: Double?
    private var scale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000
    }()
    var timing: String {
        guard let delay = lastPostDelay else { return "—" }
        return String(format: "%.1f ms", delay)
    }

    func begin(_ mouse: Mouse, in rect: CGRect) -> IOReturn {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(mouse.id))
        guard service != 0 else { return kIOReturnNoDevice }
        defer { IOObjectRelease(service) }
        guard let device = IOHIDDeviceCreate(nil, service) else { return kIOReturnNotPermitted }
        let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] ?? []
        let axes = elements.filter { IOHIDElementGetUsagePage($0) == 1 && IOHIDElementIsRelative($0) }.map(IOHIDElementGetUsage)
        guard axes.contains(48), axes.contains(49), !IOHIDDeviceConformsTo(device, 1, 6) else {
            return kIOReturnUnsupported
        }
        guard let source = CGEventSource(stateID: .privateState) else { return kIOReturnNotReady }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else { return result }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Confine gaming mouse")
        lastPostDelay = nil
        newestInput = 0
        self.device = device
        self.mouse = mouse
        self.rect = rect
        self.source = source
        source.localEventsSuppressionInterval = 0
        position = bounded(CGEvent(source: nil)?.location ?? CGPoint(x: rect.midX, y: rect.midY), in: rect)
        sent = position
        CGWarpMouseCursorPosition(position)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { ptr, status, _, value in
            guard status == 0, let ptr else { return }
            Unmanaged<InputEngine>.fromOpaque(ptr).takeUnretainedValue().input(value)
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { ptr, _, _ in
            guard let ptr else { return }
            let capture = Unmanaged<InputEngine>.fromOpaque(ptr).takeUnretainedValue()
            capture.stop()

        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        let t = Timer(timeInterval: 1.0 / 240, repeats: true) { [weak self] _ in self?.flush() }
        RunLoop.current.add(t, forMode: .common)
        timer = t
        return result
    }

    func resize(_ bounds: CGRect) {
        guard rect != bounds else { return }
        rect = bounds
        position = bounded(position, in: rect)
        flush()
    }

    func stop() {
        guard let device else { return }
        timer?.invalidate()
        timer = nil
        flush()
        for button in held { change(button, down: false) }
        mouse = nil
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        self.device = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func input(_ value: IOHIDValue) {
        guard mouse != nil, IOHIDValueGetLength(value) <= 8 else { return }
        let element = IOHIDValueGetElement(value)
        let usage = IOHIDElementGetUsage(element)
        let page = IOHIDElementGetUsagePage(element)
        let delta = IOHIDValueGetIntegerValue(value)
        if page == 1 && (usage == 48 || usage == 49) && IOHIDElementIsRelative(element) {
            guard delta != 0 else { return }
            newestInput = IOHIDValueGetTimeStamp(value)
            if usage == 48 { position.x += CGFloat(delta) * gain }
            else { position.y += CGFloat(delta) * gain }
            position = bounded(position, in: rect)
        } else if page == 9 && (1...32).contains(usage) {
            guard held.contains(usage - 1) != (delta != 0) else { return }
            flush()
            change(usage - 1, down: delta != 0)
        } else if (page == 1 && usage == 56) || (page == 12 && usage == 568) {
            guard delta != 0 else { return }
            flush()
            let step = WheelSpeed.lines(delta, multiplier: wheelSpeed)
            let scroll = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                                 wheel1: page == 1 ? step : 0, wheel2: page == 12 ? step : 0, wheel3: 0)
            scroll?.location = position
            post(scroll)
        }
    }

    private func post(_ event: CGEvent?) {
        event?.flags = CGEventSource.flagsState(.combinedSessionState)
        event?.post(tap: .cghidEventTap)
    }

    private func flush() {
        guard sent != position else { return }
        let button = held.first ?? 0
        let type: CGEventType = held.isEmpty ? .mouseMoved :
            (button == 0 ? .leftMouseDragged : button == 1 ? .rightMouseDragged : .otherMouseDragged)
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position,
                            mouseButton: CGMouseButton(rawValue: button) ?? .center)
        event?.setDoubleValueField(.mouseEventDeltaX, value: position.x - sent.x)
        event?.setDoubleValueField(.mouseEventDeltaY, value: position.y - sent.y)
        event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        post(event)
        sent = position
        let now = mach_absolute_time()
        if newestInput > 0, now >= newestInput {
            lastPostDelay = Double(now - newestInput) * scale
        }
    }

    private func change(_ button: UInt32, down: Bool) {
        guard held.contains(button) != down else { return }
        if down { held.append(button) } else { held.removeAll { $0 == button } }
        let type: CGEventType
        switch button {
        case 0: type = down ? .leftMouseDown : .leftMouseUp
        case 1: type = down ? .rightMouseDown : .rightMouseUp
        default: type = down ? .otherMouseDown : .otherMouseUp
        }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position,
                            mouseButton: CGMouseButton(rawValue: button) ?? .center)
        event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        post(event)
    }
}
