import AppKit
import SwiftUI

/// Warm Graphite follows the system appearance, including native control behavior.
enum Theme {
    static let requirementFulfilled = color("requirementFulfilled", dark: 0x8FD49D, light: 0x256B36)
    static let requirementMissing = color("requirementMissing", dark: 0xFFABA5, light: 0xA52A25)
    static let chrome = color("chrome", dark: 0x1D1D1A, light: 0xE9E8E1)
    static let editor = color("editor", dark: 0x292925, light: 0xF7F6F0)
    static let field = color("field", dark: 0x373732, light: 0xFFFFFF)
    static let toolbarPill = color("toolbarPill", dark: 0x151512, light: 0xDCDAD0)
    static let text = color("text", dark: 0xECEBE2, light: 0x292925)
    static let secondary = color("secondary", dark: 0xB7B6AD, light: 0x626157)
    static let unavailableText = color("unavailableText", dark: 0xA0A09A, light: 0x5F5F5B)
    static let accent = color("accent", dark: 0xD3B77A, light: 0x765921)
    static let selection = color("selection", dark: 0x39362A, light: 0xE3D8BD)
    static let separator = color("separator", dark: 0x484840, light: 0xD1CFC3)

    private static func color(_ name: String, dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("HandyToolbelt.\(name)")) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

struct GraphiteButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(isEnabled ? Theme.text : Theme.secondary)
            .background(configuration.isPressed ? Theme.selection : Theme.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.separator, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.55)
    }
}

/// Colors the real window chrome without changing the user's appearance preference.
struct GraphiteWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ChromeView)?.updateChrome() }
    final class ChromeView: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateChrome() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateChrome() }
        func updateChrome() {
            guard let window else { return }
            // SwiftUI updates this view during live resize too. Avoid repeatedly
            // asking AppKit to update native window chrome when it already matches.
            if !window.titlebarAppearsTransparent {
                window.titlebarAppearsTransparent = true
            }
            // The toolbar supplies its own leading title. Keep NSWindow.title for
            // accessibility, the Window menu, and window restoration.
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
            let backgroundColor = NSColor(Theme.chrome)
            if window.backgroundColor != backgroundColor {
                window.backgroundColor = backgroundColor
            }
        }
    }
}

extension View {
    func graphiteTheme() -> some View {
        self.tint(Theme.accent).foregroundStyle(Theme.text)
            .buttonStyle(GraphiteButtonStyle())
            .background(Theme.editor)
    }
    func graphiteSelection(_ selected: Bool) -> some View {
        self.listRowBackground(selected ? Theme.selection : Color.clear)
            .listItemTint(Theme.accent)
    }
}

struct HelpHint: View {
    let text: String
    @State private var showingHelp = false
    init(_ text: String) { self.text = text }
    var body: some View {
        Button { showingHelp.toggle() } label: {
            Image(systemName: "questionmark.circle").foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.plain).help(text).accessibilityLabel("Help")
        .popover(isPresented: $showingHelp) {
            Text(text).font(.callout).foregroundStyle(Theme.text).padding(16).frame(width: 300)
                .background(Theme.editor)
        }
    }
}

/// Retains NSTableView selection and keyboard behavior while rows draw the quiet selection tone.
struct GraphiteListSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ListAppearanceView() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ListAppearanceView)?.scheduleUpdate() }
    private final class ListAppearanceView: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }
        func scheduleUpdate() {
            DispatchQueue.main.async { [weak self] in self?.updateTables() }
        }
        private func updateTables() {
            func tables(in view: NSView) -> [NSTableView] {
                if let table = view as? NSTableView { return [table] }
                return view.subviews.flatMap { tables(in: $0) }
            }
            var ancestor = superview
            while let view = ancestor {
                let found = tables(in: view)
                if !found.isEmpty {
                    found.forEach { table in
                        if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                        if table.backgroundColor != .clear { table.backgroundColor = .clear }
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

/// Extends the native disclosure's pointer target through its label and row.
/// The native control still owns keyboard focus and expanded accessibility state.
struct HeaderDisclosureGroup<Content: View>: View {
    let title: String
    private let externalExpansion: Binding<Bool>?
    @State private var localExpansion = false
    let content: () -> Content

    init(_ title: String, isExpanded: Binding<Bool>? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; externalExpansion = isExpanded; self.content = content
    }
    private var expansion: Binding<Bool> { externalExpansion ?? $localExpansion }
    var body: some View {
        DisclosureGroup(isExpanded: expansion, content: content) {
            HStack { Text(title); Spacer(minLength: 0) }
                .contentShape(Rectangle())
                .onTapGesture { expansion.wrappedValue.toggle() }
        }
    }
}
