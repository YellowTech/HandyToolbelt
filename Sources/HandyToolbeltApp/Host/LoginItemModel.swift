import AppKit
import Combine
import ServiceManagement

/// System registration is the authority; constructing this model never changes login items.
/// Like the other host models, access this model on the main thread.
final class LoginItemModel: ObservableObject {
    enum Status: String, Equatable {
        case notRegistered, enabled, requiresApproval, notFound
    }

    struct Driver {
        var status: () -> Status
        var register: () throws -> Void
        var unregister: () throws -> Void
        var openSettings: () -> Void

        static let system = Driver(status: {
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .requiresApproval: return .requiresApproval
            case .notFound: return .notFound
            case .notRegistered: return .notRegistered
            @unknown default: return .notFound
            }
        }, register: { try SMAppService.mainApp.register() },
           unregister: { try SMAppService.mainApp.unregister() },
           openSettings: { SMAppService.openSystemSettingsLoginItems() })
    }

    @Published private(set) var status: Status
    @Published private(set) var errorMessage: String?
    private let driver: Driver

    init(driver: Driver = .system) {
        self.driver = driver
        status = driver.status()
    }

    var enabled: Bool { status == .enabled }

    /// An approval-pending registration remains selected so the user can cancel it.
    var isSelected: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        let next = driver.status()
        if next != status { errorMessage = nil }
        status = next
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        guard enabled != isSelected else { return }
        var failure: String?
        do {
            if enabled { try driver.register() }
            else { try driver.unregister() }
        } catch {
            failure = "Could not \(enabled ? "enable" : "disable") start at login: \(error.localizedDescription)"
        }
        refresh()
        errorMessage = failure
    }

    func openSettings() { driver.openSettings() }
}

/// Read during applicationWill/DidFinishLaunching, while the launch event is current.
/// Apple's Launch Apple Event Constants document keyAEPropData's enum value:
/// https://developer.apple.com/documentation/coreservices/apple_events/1556410-launch_apple_event_constants
/// Missing/unrecognized events are treated as ordinary launches, including app restarts.
enum LoginLaunchPolicy {
    static func isLoginItemLaunch(event: NSAppleEventDescriptor?) -> Bool {
        isLoginItemLaunch(eventClass: event?.eventClass, eventID: event?.eventID,
                          reason: event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue)
    }

    static func isLoginItemLaunch(eventClass: AEEventClass?, eventID: AEEventID?, reason: OSType?) -> Bool {
        eventClass == AEEventClass(kCoreEventClass) && eventID == AEEventID(kAEOpenApplication)
            && reason == OSType(keyAELaunchedAsLogInItem)
    }
}
