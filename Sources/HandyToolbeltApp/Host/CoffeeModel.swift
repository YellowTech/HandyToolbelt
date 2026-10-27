import Combine
import Foundation
import IOKit.pwr_mgt

/// Runtime-only selections. Held assertion IDs are the authority for effective state.
final class CoffeeModel: ObservableObject {
    enum Mode: String, CaseIterable { case preventIdleSleep, keepDisplayAwake
        var title: String { self == .preventIdleSleep ? "Prevent idle sleep" : "Keep display awake" }
        var assertionType: CFString { (self == .preventIdleSleep ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep) as CFString }
    }
    struct Driver {
        var create: (Mode) -> (IOReturn, IOPMAssertionID)
        var release: (IOPMAssertionID) -> IOReturn
        static let system = Driver(create: { mode in
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(mode.assertionType, IOPMAssertionLevel(kIOPMAssertionLevelOn), "HandyToolbelt Coffee: \(mode.title)" as CFString, &id)
            return (result, id)
        }, release: IOPMAssertionRelease)
    }
    @Published private(set) var preventIdleSleep = false
    @Published private(set) var keepDisplayAwake = false
    @Published private(set) var enabled = true
    @Published private(set) var running = false
    @Published private(set) var errorMessage: String?
    @Published private var assertions: [Mode: IOPMAssertionID] = [:]
    private let driver: Driver
    private var errors: [Mode: String] = [:]
    init(driver: Driver = .system) { self.driver = driver }
    deinit { for id in assertions.values { _ = driver.release(id) } }
    var isActive: Bool { !assertions.isEmpty }
    var controlsAvailable: Bool { running && enabled }
    func isEffective(_ mode: Mode) -> Bool { assertions[mode] != nil }
    func configure(enabled: Bool, running: Bool) {
        let changed = self.enabled != enabled || self.running != running
        self.enabled = enabled; self.running = running
        if changed { reconcile() }
    }
    func set(preventIdleSleep: Bool? = nil, keepDisplayAwake: Bool? = nil) {
        if let preventIdleSleep { self.preventIdleSleep = preventIdleSleep }
        if let keepDisplayAwake { self.keepDisplayAwake = keepDisplayAwake }
        reconcile()
    }
    func retry() { reconcile() }
    private func reconcile() {
        for mode in Mode.allCases {
            let requested = mode == .preventIdleSleep ? preventIdleSleep : keepDisplayAwake
            let desired = controlsAvailable && requested
            if desired && assertions[mode] == nil {
                let (result, id) = driver.create(mode)
                if result == kIOReturnSuccess {
                    assertions[mode] = id; errors[mode] = nil
                } else { errors[mode] = "Could not enable \(mode.title.lowercased()) (\(result)). Retry Coffee." }
            } else if !desired, let id = assertions[mode] {
                let result = driver.release(id)
                if result == kIOReturnSuccess { assertions[mode] = nil; errors[mode] = nil }
                else { errors[mode] = "Could not release \(mode.title.lowercased()) (\(result)). Retry Coffee or quit HandyToolbelt." }
            } else { errors[mode] = nil }
        }
        errorMessage = Mode.allCases.compactMap { errors[$0] }.joined(separator: " ")
        if errorMessage?.isEmpty == true { errorMessage = nil }
    }
}
