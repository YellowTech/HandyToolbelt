import AppKit
import Combine

/// A native menu keeps AppKit's keyboard navigation, outside-click dismissal and
/// accessibility. Items are retained so state can refresh while tracking, too.
final class StatusMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let host: ProductivityModel
    private let reveal: (ProductivitySection) -> Void
    private var items: [Action: NSMenuItem] = [:]
    private let coffeeError = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var subscriptions = Set<AnyCancellable>()

    enum Action: Int {
        case trackpad, chooseWindow, windows, snapping, display, power
        case preventIdleSleep, keepDisplayAwake, coffee, retryCoffee, settings, restart, quit
    }

    init(host: ProductivityModel, reveal: @escaping (ProductivitySection) -> Void) {
        self.host = host; self.reveal = reveal
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        add("Open Gestures…", .trackpad)
        add("Choose a Window…", .chooseWindow)
        add("Open Switcher…", .windows)
        add("Open Snapping…", .snapping)
        add("Open Overlays…", .display)
        add("Open Power…", .power)
        menu.addItem(.separator())
        add("Prevent idle sleep", .preventIdleSleep)
        add("Keep display awake", .keepDisplayAwake)
        coffeeError.isEnabled = false
        menu.addItem(coffeeError)
        add("Retry Coffee", .retryCoffee)
        add("Open Coffee…", .coffee)
        menu.addItem(.separator())
        add("Settings…", .settings)
        add("Restart HandyToolbelt", .restart)
        add("Quit HandyToolbelt", .quit, key: "q")
        let changes = [host.$isRestarting.map { _ in () }.eraseToAnyPublisher(),
                       host.trackpad.$configuration.map { _ in () }.eraseToAnyPublisher(),
                       host.windows.$isRunning.map { _ in () }.eraseToAnyPublisher(),
                       host.windows.$hasAccessibility.map { _ in () }.eraseToAnyPublisher(),
                       host.coffee.objectWillChange.eraseToAnyPublisher()]
        Publishers.MergeMany(changes).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }.store(in: &subscriptions)
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    func refresh() {
        items[.chooseWindow]?.isEnabled = host.windows.isRunning && host.windows.hasAccessibility
        items[.preventIdleSleep]?.state = host.coffee.preventIdleSleep ? .on : .off
        items[.keepDisplayAwake]?.state = host.coffee.keepDisplayAwake ? .on : .off
        items[.preventIdleSleep]?.isEnabled = host.coffee.controlsAvailable
        items[.keepDisplayAwake]?.isEnabled = host.coffee.controlsAvailable
        coffeeError.title = host.coffee.errorMessage ?? ""
        coffeeError.isHidden = host.coffee.errorMessage == nil
        items[.retryCoffee]?.isHidden = host.coffee.errorMessage == nil
        items[.restart]?.title = host.isRestarting ? "Restarting…" : "Restart HandyToolbelt"
        items[.restart]?.isEnabled = !host.isRestarting
    }

    private func add(_ title: String, _ action: Action, key: String = "") {
        let item = NSMenuItem(title: title, action: #selector(activateItem(_:)), keyEquivalent: key)
        item.target = self; item.tag = action.rawValue
        items[action] = item; menu.addItem(item)
    }

    @objc private func activateItem(_ item: NSMenuItem) {
        guard let action = Action(rawValue: item.tag) else { return }
        switch action {
        case .trackpad: reveal(.trackpad)
        case .chooseWindow: host.windows.show()
        case .windows: reveal(.windows)
        case .snapping: reveal(.snapping)
        case .display: reveal(.display)
        case .power: reveal(.power)
        case .preventIdleSleep: host.coffee.set(preventIdleSleep: !host.coffee.preventIdleSleep)
        case .keepDisplayAwake: host.coffee.set(keepDisplayAwake: !host.coffee.keepDisplayAwake)
        case .coffee: reveal(.coffee)
        case .retryCoffee: host.coffee.retry()
        case .settings: reveal(.settings)
        case .restart: host.restart()
        case .quit: NSApp.terminate(nil)
        }
        refresh()
    }
}

/// AppKit dismisses the popup when the status button is pressed outside it.
/// The button sends actions only on mouse-down. If AppKit forwards that same
/// dismissal press after returning from tracking, consume it exactly once.
final class StatusMenuTracking {
    private struct Press: Equatable {
        let number: Int
        let timestamp: TimeInterval
        let window: Int
        let type: NSEvent.EventType
        init(_ event: NSEvent) {
            number = event.eventNumber; timestamp = event.timestamp; window = event.windowNumber; type = event.type
        }
    }
    private(set) var isTracking = false
    private var dismissalPress: Press?

    func toggle(press: NSEvent?, cancel: () -> Void, show: () -> NSEvent?) {
        if let press {
            guard press.type != .leftMouseUp && press.type != .rightMouseUp else { return }
            if (press.type == .leftMouseDown || press.type == .rightMouseDown), dismissalPress == Press(press) {
                dismissalPress = nil; return
            }
        }
        dismissalPress = nil
        guard !isTracking else { cancel(); return }
        isTracking = true
        defer { isTracking = false }
        if let event = show(), event.type == .leftMouseDown || event.type == .rightMouseDown,
           Press(event) != press.map(Press.init) {
            dismissalPress = Press(event)
        }
    }
}

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let statusMenu: StatusMenu
    private let tracking = StatusMenuTracking()
    private let coffee: CoffeeModel
    private var subscription: AnyCancellable?
    // Cache the vector template; AppKit tints it for the current appearance.
    private let toolbeltImage: NSImage = {
        var url = Bundle.main.url(forResource: "Toolbelt", withExtension: "pdf")
        #if SWIFT_PACKAGE
        url = url ?? Bundle.module.url(forResource: "Toolbelt", withExtension: "pdf")
        #endif
        guard let url, let image = NSImage(contentsOf: url) else {
            preconditionFailure("The bundled Toolbelt.pdf resource is missing or invalid")
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }()

    // SF Symbols have their own aspect ratios; fit once without stretching.
    private let coffeeImage: NSImage? = {
        guard let image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil),
              image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(16 / image.size.width, 16 / image.size.height)
        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.isTemplate = true
        return image
    }()

    init(host: ProductivityModel, reveal: @escaping (ProductivitySection) -> Void) {
        coffee = host.coffee
        statusMenu = StatusMenu(host: host, reveal: reveal)
        // Both indicators share a compact slot matching the icon's 16pt width.
        statusItem = NSStatusBar.system.statusItem(withLength: 16)
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggleMenu(_:))
            button.imageScaling = .scaleProportionallyDown
            // The release following a cancelling press cannot open the menu.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        subscription = coffee.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.refreshIcon() }
        refreshIcon()
    }

    deinit { NSStatusBar.system.removeStatusItem(statusItem) }

    private func refreshIcon() {
        let label = coffee.isActive ? "HandyToolbelt, Coffee active" : "HandyToolbelt"
        let image = coffee.isActive
            ? coffeeImage
            : toolbeltImage
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel(label)
    }

    @objc private func toggleMenu(_ button: NSStatusBarButton) {
        tracking.toggle(press: NSApp.currentEvent, cancel: { [menu = statusMenu.menu] in menu.cancelTracking() }, show: {
            statusMenu.refresh()
            button.highlight(true)
            defer { button.highlight(false) }
            statusMenu.menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: button.bounds.minY), in: button)
            guard let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .rightMouseDown,
                  let window = button.window, event.window === window,
                  button.bounds.contains(button.convert(event.locationInWindow, from: nil)) else { return nil }
            return event
        })
    }
}
