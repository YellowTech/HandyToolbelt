import ApplicationServices
import HandyToolbeltCore

/// Worker-owned bridge from WindowServer inventory to Accessibility window roots.
final class OtherSpaceWindows {
    struct Inventory {
        var offscreenByProcess: [pid_t: Set<CGWindowID>]
        var visible: [VisibleWindowEvidence]

        init(rows: [[String: Any]], livePIDs: Set<pid_t>, assignedWindows: Set<CGWindowID>) {
            offscreenByProcess = [:]
            var onScreenRows: [[String: Any]] = []
            var onScreenIDs = Set<CGWindowID>()
            for row in rows {
                guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value, id != kCGNullWindowID,
                      let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      livePIDs.contains(pid) else { continue }
                if (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true {
                    onScreenRows.append(row)
                    onScreenIDs.insert(id)
                    continue
                }
                guard assignedWindows.contains(id), (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha.isFinite, alpha > 0,
                      let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: bounds), WindowEligibility.validFrame(frame) else { continue }
                offscreenByProcess[pid, default: []].insert(id)
            }
            for pid in Array(offscreenByProcess.keys) {
                offscreenByProcess[pid]?.subtract(onScreenIDs)
            }
            visible = WindowCatalog.visibleWindowEvidence(rows: onScreenRows)
        }
    }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias CreateElement = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let getWindow: GetWindow? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()
    private static let createElement: CreateElement? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken") else { return nil }
        return unsafeBitCast(symbol, to: CreateElement.self)
    }()
    static var isAvailable: Bool { getWindow != nil && createElement != nil }

    private typealias Connection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpaceWindows = @convention(c) (Int32, UInt32, CFArray, UInt32, UnsafePointer<UInt64>, UnsafePointer<UInt64>) -> Unmanaged<CFArray>?

    // WindowServer also reports inactive tabs and unassigned surfaces as off-screen windows.
    // Require a real Space assignment before trying to resolve any of them.
    static func assignedWindowIDs() -> Set<CGWindowID> {
        guard let skyLight else { return [] }
        let connection = skyLight.connection()
        guard let displays = skyLight.displays(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        let spaces = Set(displays.flatMap { display in
            (display["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["id64"] as? NSNumber }
        })
        guard !spaces.isEmpty else { return [] }
        var setTags: UInt64 = 0, clearTags: UInt64 = 0
        let allWindowOptions: UInt32 = 7
        guard let ids = skyLight.windows(connection, 0, Array(spaces) as CFArray, allWindowOptions, &setTags, &clearTags)?
            .takeRetainedValue() as? [NSNumber] else { return [] }
        return Set(ids.map(\.uint32Value))
    }

    private static let skyLight: (connection: Connection, displays: CopyDisplaySpaces, windows: CopySpaceWindows)? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        guard let connection = dlsym(library, "SLSMainConnectionID"),
              let displays = dlsym(library, "SLSCopyManagedDisplaySpaces"),
              let windows = dlsym(library, "SLSCopyWindowsWithOptionsAndTags") else {
            dlclose(library)
            return nil
        }
        return (unsafeBitCast(connection, to: Connection.self), unsafeBitCast(displays, to: CopyDisplaySpaces.self),
                unsafeBitCast(windows, to: CopySpaceWindows.self))
    }()

    static func id(of element: AXUIElement) -> CGWindowID? {
        var id = kCGNullWindowID
        guard getWindow?(element, &id) == .success, id != kCGNullWindowID else { return nil }
        return id
    }

    struct Search {
        var nextID: UInt64 = 0

        /// A CG ID can be returned for any AX descendant in that window. Only its root can be raised.
        mutating func find<Handle>(missing: Set<CGWindowID>, limit: UInt64, mayRead: () -> Bool,
                                   candidate: (UInt64) -> (CGWindowID, Handle)?,
                                   isWindow: (Handle) -> Bool) -> [CGWindowID: Handle] {
            var remaining = missing
            var found: [CGWindowID: Handle] = [:]
            while !remaining.isEmpty, nextID < limit, mayRead() {
                let id = nextID
                nextID += 1
                guard let (windowID, handle) = candidate(id), remaining.contains(windowID) else { continue }
                // Revisit this ID if the budget expired between the two remote reads.
                guard mayRead() else { nextID = id; break }
                guard isWindow(handle) else { continue }
                remaining.remove(windowID)
                found[windowID] = handle
            }
            return found
        }
    }

    private struct ProcessSearch {
        var targets: Set<CGWindowID>
        var search = Search()
    }
    private static let searchLimit: UInt64 = 32_768
    private var searches: [pid_t: ProcessSearch] = [:]
    private var remainingDuration: TimeInterval = 0
    private(set) var hasMoreWork = false
    private(set) var firstDeferredProcess: pid_t?

    func begin(_ inventory: Inventory) {
        searches = searches.filter { inventory.offscreenByProcess[$0.key] == $0.value.targets }
        remainingDuration = 0.2
        hasMoreWork = false
        firstDeferredProcess = nil
    }

    func reset() { searches = [:] }

    func recover(pid: pid_t, targets: Set<CGWindowID>, excluding known: Set<CGWindowID>,
                 current: () -> Bool) -> [CGWindowID: AXUIElement] {
        let missing = targets.subtracting(known)
        guard !missing.isEmpty, Self.isAvailable, let create = Self.createElement else { return [:] }
        var state = searches[pid] ?? ProcessSearch(targets: targets)
        guard state.search.nextID < Self.searchLimit else { return [:] }
        guard remainingDuration > 0 else {
            hasMoreWork = true
            if firstDeferredProcess == nil { firstDeferredProcess = pid }
            return [:]
        }
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + min(0.065, remainingDuration)
        // Remote AX tokens on macOS encode a PID, reserved field, Cocoa namespace and AX element ID.
        let header: [UInt32] = [UInt32(bitPattern: pid), 0, 0x636f636f]
        guard let token = CFDataCreateMutable(nil, 20) else { return [:] }
        CFDataSetLength(token, 20)
        guard let bytes = CFDataGetMutableBytePtr(token) else { return [:] }
        header.withUnsafeBytes { bytes.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: 12) }
        let found: [CGWindowID: AXUIElement] = state.search.find(missing: missing, limit: min(Self.searchLimit, state.search.nextID + 2_048),
            mayRead: { current() && ProcessInfo.processInfo.systemUptime < deadline },
            candidate: { index in
                var index = index
                withUnsafeBytes(of: &index) { (bytes + 12).update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: 8) }
                guard let element = create(token)?.takeRetainedValue() else { return nil }
                AXUIElementSetMessagingTimeout(element, 0.045)
                return Self.id(of: element).map { ($0, element) }
            }, isWindow: { element in
                var role: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success &&
                    role as? String == kAXWindowRole
            })
        remainingDuration -= ProcessInfo.processInfo.systemUptime - start
        searches[pid] = state
        if found.count < missing.count, state.search.nextID < Self.searchLimit { hasMoreWork = true }
        return found
    }
}
