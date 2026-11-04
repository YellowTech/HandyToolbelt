import Foundation
import Testing
@testable import HandyToolbeltCore

@Test func physicalModifiersSelectNormalBinding() {
    var config = AppConfiguration()
    let spec = GestureSpec(kind: .tap, fingers: 2)
    config.bindings = [.init(gesture: spec, action: .init(system: .nextTab), keyboardModifiers: .none), .init(gesture: spec, action: .init(system: .previousTab), keyboardModifiers: .init(mode: .exact, modifiers: [.command]))]
    #expect(config.validation().isValid)
    #expect(config.match(device: .trackpad, gesture: spec)?.action.system == .nextTab)
    #expect(config.match(device: .trackpad, gesture: spec, keyboardModifiers: [.command])?.action.system == .previousTab)
    #expect(config.match(device: .trackpad, gesture: spec, keyboardModifiers: [.option]) == nil)
}
