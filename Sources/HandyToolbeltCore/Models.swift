import Foundation

public enum InputDevice: String, Codable, CaseIterable, Identifiable, Sendable {
    case trackpad, magicMouse
    public var id: String { rawValue }
    public var title: String { self == .trackpad ? "Trackpad" : "Magic Mouse" }
    public var symbol: String { self == .trackpad ? "rectangle.and.hand.point.up.left" : "computermouse" }
}

public enum GestureKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case tap, longTouch, doubleTap, click, forceClick, tipTapLeft, tipTapRight, tipTapMiddle, tipSwipeLeft, tipSwipeRight, tipSwipeUp, tipSwipeDown, swipeLeft, swipeRight, swipeUp, swipeDown
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .tap: return "Tap"
        case .longTouch: return "Long touch"
        case .doubleTap: return "Double tap"
        case .click: return "Click"
        case .forceClick: return "Force click"
        case .tipTapLeft: return "Tip-tap left"
        case .tipTapRight: return "Tip-tap right"
        case .tipTapMiddle: return "Tip-tap middle"
        case .tipSwipeLeft: return "Anchored swipe left"
        case .tipSwipeRight: return "Anchored swipe right"
        case .tipSwipeUp: return "Anchored swipe up"
        case .tipSwipeDown: return "Anchored swipe down"
        case .swipeLeft: return "Swipe left"
        case .swipeRight: return "Swipe right"
        case .swipeUp: return "Swipe up"
        case .swipeDown: return "Swipe down"
        }
    }
    public var isTipTap: Bool { self == .tipTapLeft || self == .tipTapRight || self == .tipTapMiddle }
    public var isTipSwipe: Bool { [.tipSwipeLeft, .tipSwipeRight, .tipSwipeUp, .tipSwipeDown].contains(self) }
    public var isAnchored: Bool { isTipTap || isTipSwipe }
    public var defaultFingerCount: Int { self == .tipTapMiddle || !isAnchored ? 3 : 2 }
    public var isSwipe: Bool { [.swipeLeft, .swipeRight, .swipeUp, .swipeDown].contains(self) }
    public var symbol: String {
        switch self {
        case .tap: return "hand.tap"
        case .longTouch: return "hand.raised"
        case .doubleTap: return "hand.tap.fill"
        case .click: return "hand.point.up.left"
        case .forceClick: return "hand.point.up.left.fill"
        case .tipTapLeft: return "arrow.left.to.line"
        case .tipTapRight: return "arrow.right.to.line"
        case .tipTapMiddle: return "arrow.down.to.line"
        case .tipSwipeLeft: return "arrow.left"
        case .tipSwipeRight: return "arrow.right"
        case .tipSwipeUp: return "arrow.up"
        case .tipSwipeDown: return "arrow.down"
        case .swipeLeft: return "arrow.left"
        case .swipeRight: return "arrow.right"
        case .swipeUp: return "arrow.up"
        case .swipeDown: return "arrow.down"
        }
    }
}

public enum Corner: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, topLeft, topRight, bottomLeft, bottomRight
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "No modifier"
        case .topLeft: return "Hold top-left corner"
        case .topRight: return "Hold top-right corner"
        case .bottomLeft: return "Hold bottom-left corner"
        case .bottomRight: return "Hold bottom-right corner"
        }
    }
    public func contains(_ point: TouchPoint, size: Double = 0.22) -> Bool {
        switch self {
        case .none: return false
        case .topLeft: return point.x < size && point.y > 1 - size
        case .topRight: return point.x > 1 - size && point.y > 1 - size
        case .bottomLeft: return point.x < size && point.y < size
        case .bottomRight: return point.x > 1 - size && point.y < size
        }
    }
}

public struct GestureSpec: Codable, Hashable, Sendable {
    public var kind: GestureKind
    public var fingers: Int
    public var corner: Corner
    public init(kind: GestureKind, fingers: Int? = nil, corner: Corner = .none) {
        self.kind = kind; self.fingers = fingers ?? kind.defaultFingerCount; self.corner = corner
    }
    public var title: String { kind.isTipTap && fingers == 2 ? kind.title : "\(fingers)-finger \(kind.title.lowercased())" }
    public var heldFingerCount: Int { kind.isAnchored ? fingers - 1 : 0 }
    public var totalFingerCount: Int { fingers + (corner == .none ? 0 : 1) }
    public func allowedFingerCounts(isStackChild: Bool = false) -> [Int] {
        if kind == .forceClick { return Array(1...(corner != .none || isStackChild ? 4 : 5)) }
        if kind == .tipTapMiddle { return [3] }
        if kind.isAnchored { return Array(2...4) }
        return Array((corner != .none || isStackChild ? 1 : 2)...(corner != .none || isStackChild ? 4 : 5))
    }
    public func normalized(isStackChild: Bool = false) -> GestureSpec {
        var result = self
        result.fingers = allowedFingerCounts(isStackChild: isStackChild).min { abs(Double($0) - Double(fingers)) < abs(Double($1) - Double(fingers)) }!
        return result
    }
}

public struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt64
    public var keyLabel: String
    public init(keyCode: UInt16, modifiers: UInt64, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }
    public var display: String {
        var text = ""
        if modifiers & (1 << 18) != 0 { text += "⌃" }
        if modifiers & (1 << 19) != 0 { text += "⌥" }
        if modifiers & (1 << 17) != 0 { text += "⇧" }
        if modifiers & (1 << 20) != 0 { text += "⌘" }
        return text + keyLabel
    }
}

public enum SystemAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case previousTab, nextTab, middleClick, missionControl, showDesktop, spotlight, playPause, mute, volumeDown, volumeUp
    case nextWindow, previousWindow, showWindowSwitcher
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .previousTab: return "Previous browser tab"
        case .nextTab: return "Next browser tab"
        case .middleClick: return "Middle click"
        case .missionControl: return "Mission Control"
        case .showDesktop: return "Show desktop"
        case .spotlight: return "Spotlight"
        case .playPause: return "Play / pause"
        case .mute: return "Mute / unmute"
        case .volumeDown: return "Volume down"
        case .volumeUp: return "Volume up"
        case .nextWindow: return "Next window"
        case .previousWindow: return "Previous window"
        case .showWindowSwitcher: return "Show window switcher"
        }
    }
    public var isWindowAction: Bool { [.nextWindow, .previousWindow, .showWindowSwitcher].contains(self) }
}

public enum ActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case shortcut, system, appleScript, showText, automation, openApplication
    public var id: String { rawValue }
    public var title: String {
        switch self { case .shortcut: return "Key press"; case .system: return "System"; case .appleScript: return "AppleScript"; case .showText: return "Show Text"; case .automation: return "Automation"; case .openApplication: return "Open App" }
    }
}

public struct GestureAction: Codable, Equatable, Sendable {
    public var applicationBundleIdentifier: String = ""
    public var automationID: UUID? = nil
    public var kind: ActionKind = .system
    public var shortcut: Shortcut? = nil
    public var system: SystemAction = .nextTab
    public var script: String = ""
    public var text = ""
    public var textDuration: Double = GestureAction.defaultTextDuration
    public static let maximumTextLength = 280
    public static let maximumScriptLength = 65_536
    public static let textDurationRange: ClosedRange<Double> = 0.2...5
    public static let defaultTextDuration = 0.5
    public var displayText: String { String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumTextLength)) }
    public var displayDuration: Double { textDuration.isFinite ? min(Self.textDurationRange.upperBound, max(Self.textDurationRange.lowerBound, textDuration)) : Self.defaultTextDuration }
    private enum CodingKeys: String, CodingKey { case kind, shortcut, system, script, text, textDuration, automationID, applicationBundleIdentifier }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        applicationBundleIdentifier = try values.decodeIfPresent(String.self, forKey: .applicationBundleIdentifier) ?? ""
        kind = try values.decode(ActionKind.self, forKey: .kind)
        automationID = try values.decodeIfPresent(UUID.self, forKey: .automationID)
        shortcut = try values.decodeIfPresent(Shortcut.self, forKey: .shortcut)
        system = try values.decode(SystemAction.self, forKey: .system)
        script = try values.decode(String.self, forKey: .script)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        textDuration = try values.decodeIfPresent(Double.self, forKey: .textDuration) ?? Self.defaultTextDuration
    }
    public init(kind: ActionKind = .system, shortcut: Shortcut? = nil, system: SystemAction = .nextTab, script: String = "", text: String = "", textDuration: Double = GestureAction.defaultTextDuration, automationID: UUID? = nil, applicationBundleIdentifier: String = "") {
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.automationID = automationID
        self.kind = kind; self.shortcut = shortcut; self.system = system; self.script = script; self.text = text; self.textDuration = textDuration
    }
    public var title: String {
        switch kind {
        case .shortcut: return shortcut?.display ?? "Record a shortcut"
        case .system: return system.title
        case .appleScript: return "Run AppleScript"
        case .showText: return "Show Text"
        case .openApplication: return "Open App"
        case .automation: return "Run automation"
        }
    }
    public var isValid: Bool {
        switch kind {
        case .openApplication: return !applicationBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .automation: return automationID != nil
        case .shortcut: return shortcut != nil
        case .system: return true
        case .showText: return !displayText.isEmpty
        case .appleScript: return !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

public struct GestureBinding: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var device: InputDevice = .trackpad
    public var gesture: GestureSpec
    public var action: GestureAction
    public var isEnabled: Bool = true
    public var applicationGroupID: UUID? = nil
    public var keyboardModifiers: KeyboardModifierRequirement = .any
    public var hapticPattern: HapticPattern? = nil
    public var showsToast: Bool = true
    public init(device: InputDevice = .trackpad, gesture: GestureSpec, action: GestureAction, isEnabled: Bool = true, applicationGroupID: UUID? = nil, keyboardModifiers: KeyboardModifierRequirement = .any) {
        self.device = device; self.gesture = gesture; self.action = action; self.isEnabled = isEnabled
        self.keyboardModifiers = keyboardModifiers
        self.applicationGroupID = applicationGroupID
    }
    private enum CodingKeys: String, CodingKey { case id, device, gesture, action, isEnabled, applicationGroupID, hapticPattern, keyboardModifiers, showsToast }
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        id = try v.decode(UUID.self, forKey: .id)
        device = try v.decode(InputDevice.self, forKey: .device)
        gesture = try v.decode(GestureSpec.self, forKey: .gesture)
        action = try v.decode(GestureAction.self, forKey: .action)
        isEnabled = try v.decode(Bool.self, forKey: .isEnabled)
        applicationGroupID = try v.decodeIfPresent(UUID.self, forKey: .applicationGroupID)
        hapticPattern = try v.decodeIfPresent(HapticPattern.self, forKey: .hapticPattern)
        showsToast = try v.decodeIfPresent(Bool.self, forKey: .showsToast) ?? true
        keyboardModifiers = try v.decodeIfPresent(KeyboardModifierRequirement.self, forKey: .keyboardModifiers) ?? .any
    }
    public static let starterBindings: [GestureBinding] = [
        .init(gesture: .init(kind: .tipTapLeft), action: .init(system: .previousTab), applicationGroupID: ApplicationGroup.browsersID),
        .init(gesture: .init(kind: .tipTapRight), action: .init(system: .nextTab), applicationGroupID: ApplicationGroup.browsersID),
        .init(gesture: .init(kind: .tap, fingers: 3), action: .init(system: .middleClick)),
        .init(gesture: .init(kind: .click, fingers: 4), action: .init(system: .missionControl))
    ]
}

public struct AppConfiguration: Codable, Sendable {
    public var automations: [SavedAutomation] = []
    public var displayModuleEnabled = true
    public var powerModuleEnabled = true
    public var coffeeModuleEnabled = true
    public var snappingModuleEnabled = false
    public var stacks: [GestureStack] = []
    public var version = 6
    public var bindings: [GestureBinding] = GestureBinding.starterBindings
    public var trackpadTuning = GestureTuning()
    public var mouseTuning = GestureTuning()
    public var applicationGroups = ApplicationGroup.examples
    public var trackpadModuleEnabled = false
    public var windowSwitcher = WindowSwitcherSettings()
    public var hapticPattern: HapticPattern = .light
    public var hapticsInPractice = true
    public var visualFeedbackEnabled = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case snappingModuleEnabled, stacks, automations, powerModuleEnabled, coffeeModuleEnabled, displayModuleEnabled, version, bindings, isEnabled, trackpadTuning, mouseTuning, applicationGroups, trackpadModuleEnabled, pauseAll, windowSwitcher, hapticPattern, hapticsInPractice, visualFeedbackEnabled }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decode(Int.self, forKey: .version)
        guard (1...6).contains(storedVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported settings version.")
        }
        version = 6
        stacks = try values.decodeIfPresent([GestureStack].self, forKey: .stacks) ?? []
        automations = try values.decodeIfPresent([SavedAutomation].self, forKey: .automations) ?? []
        powerModuleEnabled = try values.decodeIfPresent(Bool.self, forKey: .powerModuleEnabled) ?? true
        coffeeModuleEnabled = try values.decodeIfPresent(Bool.self, forKey: .coffeeModuleEnabled) ?? true
        displayModuleEnabled = try values.decodeIfPresent(Bool.self, forKey: .displayModuleEnabled) ?? true
        bindings = try values.decode([GestureBinding].self, forKey: .bindings)
        trackpadTuning = try values.decodeIfPresent(GestureTuning.self, forKey: .trackpadTuning)?.validated ?? GestureTuning()
        mouseTuning = try values.decodeIfPresent(GestureTuning.self, forKey: .mouseTuning)?.validated ?? GestureTuning()
        applicationGroups = try values.decodeIfPresent([ApplicationGroup].self, forKey: .applicationGroups) ?? ApplicationGroup.examples
        trackpadModuleEnabled = try values.decodeIfPresent(Bool.self, forKey: .trackpadModuleEnabled) ?? (storedVersion < 4)
        if storedVersion < 4 {
            let paused = try values.decodeIfPresent(Bool.self, forKey: .pauseAll) ?? false
            let actions = try values.decode(Bool.self, forKey: .isEnabled)
            trackpadModuleEnabled = trackpadModuleEnabled && actions && !paused
            displayModuleEnabled = displayModuleEnabled && !paused
            coffeeModuleEnabled = coffeeModuleEnabled && !paused
        }
        windowSwitcher = try values.decodeIfPresent(WindowSwitcherSettings.self, forKey: .windowSwitcher) ?? .init()
        if storedVersion < 4, try values.decodeIfPresent(Bool.self, forKey: .pauseAll) == true { windowSwitcher.isEnabled = false }
        snappingModuleEnabled = try values.decodeIfPresent(Bool.self, forKey: .snappingModuleEnabled) ?? (windowSwitcher.isEnabled && windowSwitcher.snappingEnabled)
        windowSwitcher.snappingEnabled = false
        hapticPattern = try values.decodeIfPresent(HapticPattern.self, forKey: .hapticPattern) ?? .light
        visualFeedbackEnabled = try values.decodeIfPresent(Bool.self, forKey: .visualFeedbackEnabled) ?? false
        hapticsInPractice = try values.decodeIfPresent(Bool.self, forKey: .hapticsInPractice) ?? true
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(snappingModuleEnabled, forKey: .snappingModuleEnabled)
        try values.encode(stacks, forKey: .stacks)
        try values.encode(automations, forKey: .automations)
        try values.encode(powerModuleEnabled, forKey: .powerModuleEnabled)
        try values.encode(coffeeModuleEnabled, forKey: .coffeeModuleEnabled)
        try values.encode(displayModuleEnabled, forKey: .displayModuleEnabled)
        try values.encode(version, forKey: .version)
        try values.encode(bindings, forKey: .bindings)
        try values.encode(trackpadTuning, forKey: .trackpadTuning)
        try values.encode(mouseTuning, forKey: .mouseTuning)
        try values.encode(applicationGroups, forKey: .applicationGroups)
        try values.encode(trackpadModuleEnabled, forKey: .trackpadModuleEnabled)
        try values.encode(windowSwitcher, forKey: .windowSwitcher)
        try values.encode(hapticPattern, forKey: .hapticPattern)
        try values.encode(hapticsInPractice, forKey: .hapticsInPractice)
        try values.encode(visualFeedbackEnabled, forKey: .visualFeedbackEnabled)
    }
    public func tuning(for device: InputDevice) -> GestureTuning { device == .trackpad ? trackpadTuning : mouseTuning }
    public mutating func setTuning(_ tuning: GestureTuning, for device: InputDevice) {
        if device == .trackpad { trackpadTuning = tuning.validated } else { mouseTuning = tuning.validated }
    }
    public func scopeTitle(for binding: GestureBinding) -> String {
        guard let id = binding.applicationGroupID else { return "Everywhere" }
        return applicationGroups.first { $0.id == id }?.displayName ?? "Missing app group"
    }
    public func applies(_ binding: GestureBinding, to bundleIdentifier: String?) -> Bool {
        guard let id = binding.applicationGroupID else { return true }
        return applicationGroups.first { $0.id == id }?.contains(bundleIdentifier) ?? false
    }
    public func match(device: InputDevice, gesture: GestureSpec, frontmostBundleIdentifier: String? = nil, keyboardModifiers: Set<KeyboardModifier> = []) -> GestureBinding? {
        if gesture.corner != .none && stacks.contains(where: { $0.isEnabled && $0.device == device && $0.corner == gesture.corner && $0.keyboardModifiers.matches(keyboardModifiers) && applies($0, to: frontmostBundleIdentifier) }) { return nil }
        let candidates = bindings.filter { $0.isEnabled && $0.device == device && $0.gesture == gesture && $0.keyboardModifiers.matches(keyboardModifiers) && applies($0, to: frontmostBundleIdentifier) }
        let scoped = candidates.filter { $0.applicationGroupID != nil }
        let matches = scoped.isEmpty ? candidates : scoped
        return matches.count == 1 && matches[0].action.isValid ? matches[0] : nil
    }
    public func conflictingApplications(for binding: GestureBinding) -> [String] {
        guard let id = binding.applicationGroupID,
              let group = applicationGroups.first(where: { $0.id == id }) else { return [] }
        let duplicates = bindings.filter { $0.id != binding.id && $0.isEnabled && $0.device == binding.device && $0.gesture == binding.gesture && $0.keyboardModifiers.overlaps(binding.keyboardModifiers) && $0.applicationGroupID != nil }
        return group.applications.filter { app in
            duplicates.contains { applies($0, to: app.bundleIdentifier) }
        }.map(\.name).sorted()
    }
    public func hasConflict(_ binding: GestureBinding) -> Bool { !conflictMessages(for: binding).isEmpty }
}
