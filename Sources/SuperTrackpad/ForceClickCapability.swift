import SuperTrackpadCore

/// Capability of the selected device family; mappings remain editable in every state.
enum ForceClickCapability: Equatable {
    case noTrackpad, unsupportedTrackpad, supportedTrackpad, mixedTrackpads, magicMouse

    init(device: InputDevice, connected: [TouchDevice]) {
        guard device == .trackpad else { self = .magicMouse; return }
        let trackpads = connected.filter { $0.kind == .trackpad }
        if trackpads.isEmpty { self = .noTrackpad }
        else if !trackpads.contains(where: \.supportsForce) { self = .unsupportedTrackpad }
        else if trackpads.contains(where: { !$0.supportsForce }) { self = .mixedTrackpads }
        else { self = .supportedTrackpad }
    }

    func message(includeClickTiming: Bool = true) -> String {
        switch self {
        case .noTrackpad:
            return "No trackpad detected. Connect a Force Touch trackpad to use this gesture."
        case .unsupportedTrackpad:
            return "The connected trackpad does not support Force click. Ordinary Click actions still run immediately."
        case .magicMouse:
            return "Magic Mouse does not support Force click. Ordinary Click actions still run immediately."
        case .supportedTrackpad, .mixedTrackpads:
            let capability = self == .mixedTrackpads
                ? "Force click works only on Force Touch trackpads; other trackpads keep immediate Click actions."
                : "Force Touch available."
            return capability + " The native app click may also occur." + (includeClickTiming
                ? " A matching Click action on a Force Touch trackpad waits for release." : "")
        }
    }
}
