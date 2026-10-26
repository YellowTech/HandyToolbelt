import AppKit
import SwiftUI

/// Keep navigation in one trailing native item so Settings cannot overflow on its own.
struct ProductivityToolbar: ToolbarContent {
    @ObservedObject var host: ProductivityModel
    @ObservedObject var trackpad: AppModel
    @ObservedObject var snapping: WindowSnappingModel

    init(host: ProductivityModel, trackpad: AppModel) {
        self.host = host; self.trackpad = trackpad; snapping = host.snapping
    }

    private let tools: [ProductivitySection] = [.trackpad, .windows, .snapping, .display, .power, .coffee]

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text("HandyToolbelt")
                .font(.headline)
                .foregroundStyle(Theme.text)
                .padding(.leading, 8)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
        }
        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible)
        } else {
            ToolbarItem { Spacer() }
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 6) {
                ForEach(tools + [.settings]) { tool in moduleTab(tool) }
            }
            .accessibilityElement(children: .contain)
            .fixedSize()
            .padding(.vertical, 3)
            .transaction { $0.animation = nil }
        }
    }

    private func status(_ section: ProductivitySection) -> String {
        let enabled: Bool
        switch section {
        case .trackpad: enabled = trackpad.configuration.trackpadModuleEnabled
        case .windows: enabled = trackpad.configuration.windowSwitcher.isEnabled
        case .snapping:
            if !snapping.eligible { return "Automatically disabled" }
            enabled = trackpad.configuration.snappingModuleEnabled
        case .display: enabled = trackpad.configuration.displayModuleEnabled
        case .coffee: enabled = trackpad.configuration.coffeeModuleEnabled
        case .power: enabled = trackpad.configuration.powerModuleEnabled
        case .settings: return ""
        }
        return !enabled ? "Off" : ""
    }

    private func moduleTab(_ section: ProductivitySection) -> some View {
        let selected = host.section == section
        let state = status(section)
        let accessibleTitle = section == .settings ? "Global Settings" : section.title
        return Button { host.section = section } label: {
            pill(title: section.title, symbol: section.symbol, status: state, selected: selected)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibleTitle))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { host.section = section }
        .accessibilityValue([selected ? "Selected" : "", state].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .id(section)
        .help(state == "Automatically disabled" ? "Snapping is automatically disabled while displays have separate Spaces; macOS window tiling is available." : state == "Off" ? "\(section.title) is off. Open this tab for help enabling it in Settings." : "Open \(accessibleTitle)")
    }

    private func pill(title: String, symbol: String, status: String, selected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            if title != ProductivitySection.settings.title { Text(title) }
        }
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(labelColor(status: status, selected: selected))
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(selected ? Theme.selection : Theme.toolbarPill, in: Capsule())
        .overlay(Capsule().strokeBorder(selected ? Theme.accent.opacity(0.5) : Theme.separator, lineWidth: 1))
        .contentShape(Capsule())
    }

    private func labelColor(status: String, selected: Bool) -> Color {
        if !status.isEmpty { return Theme.unavailableText }
        return selected ? Theme.accent : Theme.text
    }
}

extension View {
    @ViewBuilder
    func hideDefaultToolbarTitle() -> some View {
        if #available(macOS 15, *) { toolbar(removing: .title) }
        else { self } // GraphiteWindowChrome supplies the AppKit fallback on macOS 14.
    }
}
