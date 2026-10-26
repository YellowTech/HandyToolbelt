import Foundation
import Combine
import IOKit.ps
import IOKit
import AppKit

/// A reading from the built-in battery only. Optional values stay unknown.
struct PowerReading: Equatable {
    var batteryPresent: Bool? = nil
    var chargePercent: Int? = nil
    var isCharging: Bool? = nil
    var isCharged: Bool? = nil
    var powerSource: String? = nil

    var cycleCount: Int? = nil
    var designCapacityMAh: Double? = nil
    var fullChargeCapacityMAh: Double? = nil
    var nominalChargeCapacityMAh: Double? = nil
    var estimatedHealthPercent: Double? = nil
    var healthEstimateSource: String? = nil
    var adapterWatts: Double? = nil
    var adapterName: String? = nil
    var externalConnected: Bool? = nil
    var batteryWatts: Double? = nil
    var inputWatts: Double? = nil
    var systemLoadWatts: Double? = nil
    var estimatedMacWatts: Double? = nil

    /// Registry MaxCapacity is often a percentage. Never interpret it as mAh.
    mutating func mergeRegistry(_ root: [String: Any], adapter: [String: Any] = [:]) {
        let data = root["BatteryData"] as? [String: Any] ?? [:]
        let telemetry = root["PowerTelemetryData"] as? [String: Any] ?? [:]
        func valid(_ value: Any?, _ range: ClosedRange<Double>) -> Double? {
            guard let number = value as? NSNumber else { return nil }
            let result = number.doubleValue
            return result.isFinite && range.contains(result) ? result : nil
        }
        designCapacityMAh = valid(data["DesignCapacity"] ?? root["DesignCapacity"], 100...100_000)
        fullChargeCapacityMAh = valid(data["FullChargeCapacity"] ?? root["AppleRawMaxCapacity"] ?? root["FullChargeCapacity"], 100...100_000)
        cycleCount = valid(data["CycleCount"] ?? root["CycleCount"], 0...100_000).map(Int.init)
        nominalChargeCapacityMAh = valid(data["NominalChargeCapacity"] ?? root["NominalChargeCapacity"], 100...100_000)
        estimatedHealthPercent = nil; healthEstimateSource = nil
        if let nominal = nominalChargeCapacityMAh, let design = designCapacityMAh, nominal / design <= 1.2 {
            estimatedHealthPercent = min(100, (nominal / design * 100).rounded())
            healthEstimateSource = "nominalCapacity"
        } else if let full = fullChargeCapacityMAh, let design = designCapacityMAh, full / design <= 1.2 {
            estimatedHealthPercent = full / design * 100
            healthEstimateSource = "fullChargeCapacity"
        }
        externalConnected = root["ExternalConnected"] as? Bool
        if let voltage = valid(root["Voltage"], 1_000...30_000), let current = Self.signedCurrent(root["Amperage"] ?? root["InstantAmperage"]) {
            let watts = voltage * current / 1_000_000
            if abs(watts) <= 500 { batteryWatts = watts }
        }
        if externalConnected == true {
            inputWatts = valid(telemetry["SystemPowerIn"], 0...500_000).map { $0 / 1_000 }
            systemLoadWatts = valid(telemetry["SystemLoad"], 0...500_000).map { $0 / 1_000 }
            adapterWatts = valid(adapter["Watts"], 1...500)
            if let name = adapter["Name"] as? String, !name.isEmpty { adapterName = String(name.prefix(120)) }
        }
        if externalConnected == false, let batteryWatts, batteryWatts <= 0 {
            estimatedMacWatts = -batteryWatts
        } else if externalConnected == true {
            if let systemLoadWatts { estimatedMacWatts = systemLoadWatts }
            else if let inputWatts, let batteryWatts {
                let load = inputWatts - batteryWatts
                if (0...500).contains(load) { estimatedMacWatts = load }
            }
        }
    }
    static func signedCurrent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        var current = number.doubleValue
        if current > Double(Int64.max) { current = Double(Int64(bitPattern: number.uint64Value)) }
        else if current > Double(Int32.max), current <= Double(UInt32.max) { current = Double(Int32(bitPattern: number.uint32Value)) }
        return current.isFinite && abs(current) <= 30_000 ? current : nil
    }

    static func decode(_ sources: [[String: Any]]) -> PowerReading {
        guard let battery = sources.first(where: { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }) else {
            return PowerReading(batteryPresent: false)
        }
        let current = battery[kIOPSCurrentCapacityKey] as? Int
        let maximum = battery[kIOPSMaxCapacityKey] as? Int
        let percent: Int?
        if let current, let maximum, maximum > 0, current >= 0, current <= maximum {
            percent = Int((Double(current) / Double(maximum) * 100).rounded())
        } else { percent = nil }
        let source = battery[kIOPSPowerSourceStateKey] as? String
        return PowerReading(batteryPresent: battery[kIOPSIsPresentKey] as? Bool ?? true,
            chargePercent: percent, isCharging: battery[kIOPSIsChargingKey] as? Bool,
            isCharged: battery[kIOPSIsChargedKey] as? Bool,
            powerSource: source == kIOPSACPowerValue ? "ac" : (source == kIOPSBatteryPowerValue ? "battery" : nil))
    }
}

/// Direction comes from signed battery telemetry, never adapter capacity or a missing value.
enum PowerFlowState: Equatable {
    case charging, batteryDischarging, batteryAssisting, idle, disconnected, unavailable, settling

    static func resolve(_ reading: PowerReading, settling: Bool) -> Self {
        if settling { return .settling }
        guard reading.batteryPresent != false, let connected = reading.externalConnected else { return .unavailable }
        if (connected && reading.powerSource == "battery") || (!connected && reading.powerSource == "ac") { return .unavailable }
        guard let watts = reading.batteryWatts, watts.isFinite else { return .unavailable }
        if !connected {
            guard watts <= 0, reading.isCharging != true else { return .unavailable }
            return watts < 0 ? .batteryDischarging : .disconnected
        }
        if watts > 0 { return reading.isCharging == false ? .unavailable : .charging }
        if watts < 0 { return reading.isCharging == true ? .unavailable : .batteryAssisting }
        return reading.isCharging == true ? .unavailable : .idle
    }
    var batterySupplies: Bool { self == .batteryDischarging || self == .batteryAssisting }
    var batteryCharges: Bool { self == .charging }
    var permitsAdapterFlow: Bool { self == .charging || self == .batteryAssisting || self == .idle }
    var status: String {
        switch self {
        case .charging: return "Charging battery"
        case .batteryDischarging: return "Using battery"
        case .batteryAssisting: return "Battery assisting adapter"
        case .idle: return "Battery idle"
        case .disconnected: return "Adapter disconnected"
        case .unavailable: return "Flow unavailable"
        case .settling: return "Updating power flow…"
        }
    }
}

final class PowerModel: ObservableObject {
    struct Driver {
        var read: () -> PowerReading
        /// Returns cancellation; nil means notifications could not be registered.
        var observe: (@escaping () -> Void) -> (() -> Void)?
        static let system = Driver(read: {
            guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                  let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return PowerReading() }
            var reading = PowerReading.decode(list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] })
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                var properties: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let root = properties?.takeRetainedValue() as? [String: Any] {
                    let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] ?? [:]
                    reading.mergeRegistry(root, adapter: adapter)
                }
            }
            return reading
        }, observe: { changed in
            let context = PowerNotificationContext(changed)
            let pointer = Unmanaged.passRetained(context).toOpaque()
            guard let source = IOPSNotificationCreateRunLoopSource({ pointer in
                guard let pointer else { return }
                Unmanaged<PowerNotificationContext>.fromOpaque(pointer).takeUnretainedValue().changed()
            }, pointer)?.takeRetainedValue() else {
                Unmanaged<PowerNotificationContext>.fromOpaque(pointer).release()
                return nil
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            return {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                CFRunLoopSourceInvalidate(source)
                Unmanaged<PowerNotificationContext>.fromOpaque(pointer).release()
            }
        })
    }
    @Published private(set) var reading = PowerReading()
    @Published private(set) var enabled = true
    @Published private(set) var running = false
    @Published private(set) var isLive = false
    @Published private(set) var isSettling = false
    var flowState: PowerFlowState { .resolve(reading, settling: isSettling) }
    @Published private(set) var errorMessage: String?
    struct Scheduler {
        var repeatEvery: (TimeInterval, @escaping () -> Void) -> (() -> Void)
        static let system = Scheduler { interval, action in
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in action() }
            return { timer.invalidate() }
        }
    }
    private let driver: Driver
    private let scheduler: Scheduler
    private let isFrontmost: () -> Bool
    private let now: () -> Date
    private var cancelObservation: (() -> Void)?
    private var cancelTimer: (() -> Void)?
    private var lockObservers: [NSObjectProtocol] = []
    private var lifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var requestedRunning = false
    private var sessionActive = true
    private var visible = false
    private var lastSource: Bool?
    private var smoothed: Double?
    private var settleUntil: Date?
    init(driver: Driver = .system,
         scheduler: Scheduler = .system, now: @escaping () -> Date = Date.init,
         isFrontmost: @escaping () -> Bool = { NSApp?.isActive == true && NSApp?.mainWindow?.isVisible == true && NSApp?.mainWindow?.isMiniaturized == false && NSApp?.keyWindow === NSApp?.mainWindow }, observeLifecycle: Bool = true) {
        self.driver = driver; self.scheduler = scheduler; self.now = now; self.isFrontmost = isFrontmost
        if observeLifecycle {
            sessionActive = Self.currentSessionIsActive()
            for rawName in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
                lockObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(rawName), object: nil, queue: .main) { [weak self] note in
                    self?.setSessionActive(note.name.rawValue == "com.apple.screenIsUnlocked" && Self.currentSessionIsActive())
                })
            }
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                lifecycleObservers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setSessionActive(false) }))
            }
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
                lifecycleObservers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setSessionActive(Self.currentSessionIsActive()) }))
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                lifecycleObservers.append((.default, NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.restartTimer() }))
            }
        }
    }
    deinit {
        cancelObservation?(); cancelTimer?()
        lockObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        lifecycleObservers.forEach { $0.0.removeObserver($0.1) }
    }
    private static func currentSessionIsActive() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session[kCGSessionOnConsoleKey as String] as? Bool ?? false) && !(session["CGSSessionScreenIsLocked"] as? Bool ?? false)
    }
    func setVisible(_ value: Bool) { visible = value; restartTimer() }
    func setSessionActive(_ value: Bool) {
        sessionActive = value; reconcile()
    }
    func configure(enabled: Bool, running: Bool) {
        self.enabled = enabled; requestedRunning = running; reconcile()
    }
    private func reconcile() {
        let desired = enabled && requestedRunning && sessionActive
        guard desired != running else { return }
        running = desired
        smoothed = nil; lastSource = nil; settleUntil = nil
        if desired {
            refresh()
            cancelObservation = driver.observe { [weak self] in self?.refresh(smooth: self?.liveActive == true) }
            errorMessage = cancelObservation == nil ? "Battery updates are unavailable. Turn Power off and on in Settings to retry." : nil
            restartTimer()
        } else {
            cancelObservation?(); cancelObservation = nil; cancelTimer?(); cancelTimer = nil
            reading = PowerReading(); errorMessage = nil; isLive = false; isSettling = false
        }
    }
    private var liveActive: Bool { visible && isFrontmost() }
    func refreshForStatus() { refresh(smooth: liveActive) }
    private func restartTimer() {
        cancelTimer?(); cancelTimer = nil
        isLive = running && liveActive
        guard running else { return }
        let live = liveActive
        if !live { smoothed = nil }
        guard live else { return }
        refresh(smooth: true)
        cancelTimer = scheduler.repeatEvery(2) { [weak self] in
            guard let self else { return }
            guard self.running && self.liveActive else { self.restartTimer(); return }
            self.refresh(smooth: true)
        }
    }
    private func refresh(smooth: Bool = false) {
        guard running else { return }
        var value = driver.read()
        let date = now()
        if value.externalConnected != lastSource {
            smoothed = nil; settleUntil = date.addingTimeInterval(4)
            lastSource = value.externalConnected
        }
        isSettling = settleUntil.map { date < $0 } ?? false
        if isSettling { value.estimatedMacWatts = nil; value.inputWatts = nil; value.systemLoadWatts = nil }
        if smooth, let watts = value.estimatedMacWatts {
            smoothed = smoothed.map { $0 * 0.5 + watts * 0.5 } ?? watts
            value.estimatedMacWatts = smoothed
        } else { smoothed = nil }
        reading = value
    }

}
private final class PowerNotificationContext {
    let changed: () -> Void
    init(_ changed: @escaping () -> Void) { self.changed = changed }
}
