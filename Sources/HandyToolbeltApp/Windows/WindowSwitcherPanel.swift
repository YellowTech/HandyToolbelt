import AppKit
import SwiftUI
import HandyToolbeltCore

final class WindowSwitcherPanel: NSPanel {
    private weak var model: WindowSwitcherModel?
    init(model: WindowSwitcherModel) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: 570, height: 420), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isFloatingPanel = true; hidesOnDeactivate = false; isReleasedWhenClosed = false
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        contentView = NSHostingView(rootView: WindowChooserView(model: model))
        setAccessibilityLabel("HandyToolbelt window switcher")
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let area = screen?.visibleFrame, let model {
            let size = WindowChooserGeometry.size(available: area.size, layout: model.settings.layout, previews: model.settings.showsPreviews, previewScale: model.settings.previewScale, gridScale: model.settings.gridScale)
            model.updateChooserWidth(size.width)
            setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: false)
        }
        orderFrontRegardless()
    }
}

private struct WindowChooserView: View {
    @ObservedObject var model: WindowSwitcherModel
    var body: some View {
        WindowChooserContent(items: model.items, settings: model.settings, selectedID: model.selectedID,
                             isLoading: model.isLoading, message: model.message, images: model.previews.images,
                             hasPreviewPermission: model.previews.hasPermission, onChoose: model.choose,
                             onCancel: model.cancel, onVisible: model.updateVisiblePreviews)
    }
}

/// Immutable presentation data also lets the development harness render the real chooser.
struct WindowChooserContent: View {
    var items: [WindowItem]
    var settings: WindowSwitcherSettings
    var selectedID: UUID?
    var isLoading: Bool
    var message: String
    var images: [UUID: NSImage]
    var hasPreviewPermission: Bool
    var onChoose: (UUID) -> Void
    var onCancel: () -> Void
    var onVisible: (Set<UUID>) -> Void
    var exampleMode = false
    var iconProvider: ((WindowItem) -> AnyView)? = nil
    var previewProvider: ((WindowItem) -> AnyView)? = nil

    var body: some View {
        VStack(spacing: 0) {
            if !exampleMode {
                HStack {
                    Label("Switcher", systemImage: "macwindow.on.rectangle").font(.headline)
                    Spacer()
                    Text(isLoading ? "" : "\(items.count) windows").font(.caption).foregroundStyle(Theme.secondary)
                    Button(action: onCancel) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Cancel window switch")
                }.padding(18)
                Divider()
            }
            if isLoading {
                VStack(spacing: 12) { ProgressView(); Text("Finding windows…").foregroundStyle(Theme.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text(message).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                    .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { choices }
            if !exampleMode {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if settings.showsPreviews && !hasPreviewPermission {
                        Text("Allow Screen & System Audio Recording in Global Settings for previews.")
                    }
                    Text("Tab / arrows to choose · Shift back · Enter to switch · Esc to cancel")
                }.font(.caption).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.separator))
        .tint(Theme.accent).foregroundStyle(Theme.text)
        .onDisappear { onVisible([]) }
    }

    private var choices: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    if settings.layout == .grid {
                        let count = WindowChooserGeometry.columns(width: viewport.size.width, previews: settings.showsPreviews, previewScale: settings.previewScale)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: count), spacing: 8) {
                            ForEach(items) { item in choice(item, grid: true) }
                        }.padding(8)
                    } else {
                        LazyVStack(spacing: 3) {
                            ForEach(items) { item in choice(item, grid: false) }
                        }.padding(8)
                    }
                }
                .coordinateSpace(name: "WindowChooserViewport")
                .onPreferenceChange(WindowChooserFrames.self) { frames in
                    let bounds = CGRect(origin: .zero, size: viewport.size)
                    onVisible(Set(frames.filter { bounds.intersects($0.value) }.keys))
                }
                .onAppear { if let selectedID { proxy.scrollTo(selectedID, anchor: .center) } }
                .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private func choice(_ item: WindowItem, grid: Bool) -> some View {
        Button { onChoose(item.id) } label: {
            Group {
                if grid {
                    VStack(alignment: .leading, spacing: 9) {
                        if settings.showsPreviews { preview(item).frame(height: 124 * WindowSwitcherSettings.validatedPreviewScale(settings.previewScale)) }
                        else {
                            appIcon(item).frame(width: 44, height: 44)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        title(item, grid: true)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 12) {
                        if settings.showsPreviews { preview(item).frame(width: 128 * WindowSwitcherSettings.validatedPreviewScale(settings.previewScale), height: 80 * WindowSwitcherSettings.validatedPreviewScale(settings.previewScale)) }
                        else { appIcon(item).frame(width: 32, height: 32) }
                        title(item, grid: false)
                        Spacer(minLength: 4)
                        if selectedID == item.id { Image(systemName: "arrow.turn.down.left").accessibilityHidden(true) }
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Theme.text)
        .background(selectedID == item.id ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selectedID == item.id ? Theme.accent.opacity(0.7) : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
        .id(item.id)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: WindowChooserFrames.self, value: [item.id: geometry.frame(in: .named("WindowChooserViewport"))])
            }
        }
    }

    private func title(_ item: WindowItem, grid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(grid ? 2 : 1)
                .frame(height: grid ? 34 : nil, alignment: .topLeading)
            HStack(spacing: 5) {
                if settings.showsPreviews { appIcon(item).frame(width: 16, height: 16) }
                Text(item.appName + (item.isMinimized ? " · Minimized" : "") + (item.isHidden ? " · Hidden" : ""))
                .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func appIcon(_ item: WindowItem) -> some View {
        if let iconProvider { iconProvider(item) }
        else { WindowAppIcon(processID: item.processID) }
    }

    private func preview(_ item: WindowItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Theme.editor)
            if let previewProvider {
                previewProvider(item).padding(2).accessibilityLabel("Illustrated example window")
            } else if let image = images[item.id] {
                Image(nsImage: image).resizable().scaledToFit().padding(2).accessibilityLabel("Window preview")
            } else {
                appIcon(item).frame(width: 32, height: 32)
                    .accessibilityLabel("Preview unavailable")
            }
        }.frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct WindowChooserFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct WindowAppIcon: View {
    let processID: Int32
    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: processID)?.icon {
            Image(nsImage: icon).resizable().scaledToFit().accessibilityHidden(true)
        } else { Image(systemName: "macwindow").resizable().scaledToFit().accessibilityHidden(true) }
    }
}
