import AppKit
import Darwin
import IOKit
import HandyToolbeltCore

struct TouchDevice: Identifiable, Equatable {
    let id: UInt64
    let kind: InputDevice
    let name: String
    let aspectRatio: Double
    let hasMeasuredAspect: Bool
    let supportsForce: Bool
}

/// The only private-API boundary. No headers, bridging module, or third-party library required.
/// Never retain callback memory: copy validated contacts before returning to the driver.
final class MultitouchInput {
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Callback = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Void
    private typealias Register = @convention(c) (UnsafeRawPointer, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeRawPointer, Int32) -> Int32
    private typealias Stop = @convention(c) (UnsafeRawPointer) -> Int32
    private typealias Service = @convention(c) (UnsafeRawPointer) -> UInt32
    private typealias DeviceID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias Dimensions = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias SupportsForce = @convention(c) (UnsafeRawPointer) -> Bool

    private static weak var active: MultitouchInput?
    private let handle: UnsafeMutableRawPointer
    private let createList: CreateList
    private let register: Register
    private let unregister: Register
    private let startDevice: Start
    private let stopDevice: Stop
    private let service: Service
    private let deviceID: DeviceID
    private let dimensions: Dimensions?
    private let supportsForce: SupportsForce?
    private var retainedList: CFArray?
    private var pointers: [UInt: (UnsafeRawPointer, TouchDevice)] = [:]
    private var startedAt = ProcessInfo.processInfo.systemUptime
    var onFrame: ((TouchDevice, [Contact], Double) -> Void)?
    var onDevicesChanged: (([TouchDevice]) -> Void)?
    var onError: ((String) -> Void)?

    init() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL) else {
            throw InputError.unavailable("This version of macOS does not provide the multitouch framework.")
        }
        func resolve<T>(_ name: String, as type: T.Type) throws -> T {
            guard let symbol = dlsym(handle, name) else { throw InputError.unavailable("Multitouch support is missing \(name).") }
            return unsafeBitCast(symbol, to: type)
        }
        do {
            createList = try resolve("MTDeviceCreateList", as: CreateList.self)
            register = try resolve("MTRegisterContactFrameCallback", as: Register.self)
            unregister = try resolve("MTUnregisterContactFrameCallback", as: Register.self)
            startDevice = try resolve("MTDeviceStart", as: Start.self)
            stopDevice = try resolve("MTDeviceStop", as: Stop.self)
            service = try resolve("MTDeviceGetService", as: Service.self)
            deviceID = try resolve("MTDeviceGetDeviceID", as: DeviceID.self)
            dimensions = dlsym(handle, "MTDeviceGetSensorSurfaceDimensions").map { unsafeBitCast($0, to: Dimensions.self) }
            supportsForce = dlsym(handle, "MTDeviceSupportsForce").map { unsafeBitCast($0, to: SupportsForce.self) }
        } catch { dlclose(handle); throw error }
        self.handle = handle
        Self.active = self
    }

    enum InputError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { if case let .unavailable(reason) = self { return reason }; return nil }
    }

    func refresh(force: Bool = false) {
        precondition(Thread.isMainThread)
        let list = createList()?.takeRetainedValue()
        var found: [(UnsafeRawPointer, TouchDevice)] = []
        if let list {
            for index in 0..<CFArrayGetCount(list) {
                guard let pointer = CFArrayGetValueAtIndex(list, index) else { continue }
                let io = service(pointer)
                let product = IORegistryEntrySearchCFProperty(io, kIOServicePlane, "Product" as CFString, kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String ?? ""
                let kind: InputDevice
                if product.localizedCaseInsensitiveContains("trackpad") { kind = .trackpad }
                else if product.localizedCaseInsensitiveContains("magic mouse") || product.localizedCaseInsensitiveContains("magicmouse") { kind = .magicMouse }
                else { continue } // Do not treat Touch Bar and other digitizers as trackpads.
                var id: UInt64 = 0
                guard deviceID(pointer, &id) == 0 else { continue }
                let name = product.contains("Internal") ? "Built-in trackpad" : product
                var width: Int32 = 0, height: Int32 = 0
                let measured = dimensions?(pointer, &width, &height) == 0 && width > 0 && height > 0 && (0.5...4).contains(Double(width) / Double(height))
                found.append((pointer, TouchDevice(id: id, kind: kind, name: name,
                    aspectRatio: measured ? Double(width) / Double(height) : 1.6, hasMeasuredAspect: measured,
                    supportsForce: supportsForce?(pointer) ?? false)))
            }
        }
        let previous = Set(pointers.values.map { $0.1.id })
        guard force || previous != Set(found.map { $0.1.id }) else { return }
        stop()
        retainedList = list
        Self.active = self
        for (pointer, info) in found {
            pointers[UInt(bitPattern: pointer)] = (pointer, info)
            register(pointer, Self.callback)
            let result = startDevice(pointer, 0)
            if result != 0 {
                unregister(pointer, Self.callback)
                pointers.removeValue(forKey: UInt(bitPattern: pointer))
                onError?("Could not start \(info.name) (\(result)). Reconnect the device and retry.")
            }
        }
        onDevicesChanged?(pointers.values.map { $0.1 }.sorted { $0.id < $1.id })
    }

    func stop() {
        precondition(Thread.isMainThread)
        startedAt = ProcessInfo.processInfo.systemUptime
        // Stop delivery before unregistering and releasing the owning CFArray.
        for (pointer, _) in pointers.values { _ = stopDevice(pointer); unregister(pointer, Self.callback) }
        pointers.removeAll()
        retainedList = nil
    }

    // Library remains loaded for the process lifetime: a driver callback may still be unwinding.
    private static let callback: Callback = { device, data, count, _, _ in
        guard let device, count >= 0 && count <= 10, count == 0 || data != nil else { return }
        let key = UInt(bitPattern: device)
        var contacts: [Contact] = []
        if let data {
            for index in 0..<Int(count) {
                let touch = data.advanced(by: index * 96)
                let stage = touch.loadUnaligned(fromByteOffset: 20, as: Int32.self)
                guard stage == 3 || stage == 4 else { continue }
                let id = Int(touch.loadUnaligned(fromByteOffset: 16, as: Int32.self))
                let x = Double(touch.loadUnaligned(fromByteOffset: 32, as: Float.self))
                let y = Double(touch.loadUnaligned(fromByteOffset: 36, as: Float.self))
                guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return }
                // zPressure, not zTotal (contact quality) or contact area. Capability-gated below.
                let pressure = Double(touch.loadUnaligned(fromByteOffset: 52, as: Float.self))
                contacts.append(Contact(id: id, x: x, y: y, pressure: pressure))
            }
        }
        let copied = contacts
        let timestamp = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async {
            guard let input = MultitouchInput.active, let (_, info) = input.pointers[key], timestamp >= input.startedAt,
                  ProcessInfo.processInfo.systemUptime - timestamp < 0.25 else { return }
            let validated = info.supportsForce ? copied : copied.map { contact in
                var contact = contact; contact.pressure = nil; return contact
            }
            input.onFrame?(info, validated, timestamp)
        }
    }
}
