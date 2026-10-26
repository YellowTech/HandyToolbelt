import AppKit
import SwiftUI

/// Lazily retain the finite set of navigation destinations without laying out
/// inactive ones. Detached hosts have no window, drawing clock, event or AX tree.
struct CachedHostingSurface<Selection: Hashable & CaseIterable>: NSViewRepresentable {
    let selection: Selection
    let content: (Selection) -> AnyView

    func makeNSView(context: Context) -> Container { Container() }
    func updateNSView(_ view: Container, context: Context) {
        view.select(selection, content: content)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 980,
               height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 500)
    }

    final class Container: NSView {
        private var hosts: [Selection: NSHostingView<AnyView>] = [:]
        private var selected: Selection?
        private var active: NSHostingView<AnyView>?
        override var isFlipped: Bool { true }

        func select(_ destination: Selection, content: (Selection) -> AnyView) {
            guard selected != destination else { return }
            window?.makeFirstResponder(nil)
            active?.removeFromSuperview()
            let next: NSHostingView<AnyView>
            if let cached = hosts[destination] { next = cached }
            else {
                next = NSHostingView(rootView: content(destination))
                // Each destination receives the available window bounds. Its
                // content must not feed intrinsic size back into the parent.
                next.sizingOptions = []
                hosts[destination] = next
            }
            selected = destination; active = next
            next.frame = bounds
            addSubview(next)
            needsLayout = true
        }
        override func layout() {
            super.layout()
            active?.frame = bounds
        }
    }
}

// Each cache is bounded by its navigation enum and created only on first visit.
typealias WorkspaceHostingSurface = CachedHostingSurface<TrackpadWorkspace>
typealias ModuleHostingSurface = CachedHostingSurface<ProductivitySection>
