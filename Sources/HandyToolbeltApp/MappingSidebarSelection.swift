import Foundation

/// Native row identity includes its category and parent; imported UUIDs may overlap.
enum MappingSidebarSelection: Hashable {
    case binding(UUID)
    case stack(UUID)
    case child(stack: UUID, child: UUID)
}

extension AppModel {
    var sidebarSelection: MappingSidebarSelection? {
        get {
            if let selectedID { return .binding(selectedID) }
            if let selectedStackID {
                if let selectedStackChildID { return .child(stack: selectedStackID, child: selectedStackChildID) }
                return .stack(selectedStackID)
            }
            return nil
        }
        set {
            guard newValue != sidebarSelection else { return }
            switch newValue {
            case let .binding(id): selectedID = id
            case let .stack(id): selectedStackID = id; selectedStackChildID = nil
            case let .child(stack, child): selectStackChild(child, in: stack)
            case nil: selectedID = nil; selectedStackID = nil; selectedStackChildID = nil
            }
        }
    }
}
