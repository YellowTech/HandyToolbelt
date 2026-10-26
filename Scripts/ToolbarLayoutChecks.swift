// Native sizing regression, using the shipped content constraints:
// xcrun swiftc -parse-as-library Sources/SuperTrackpad/Host/MainWindowLayout.swift Scripts/ToolbarLayoutChecks.swift -o /tmp/SuperTools-toolbar-checks
// Run from the repository root.
import AppKit
import SwiftUI

@main
struct ToolbarLayoutChecks {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        var count = 0
        let controller = NSHostingController(rootView: Color.clear.mainWindowContentSize())
        for proposal in [CGSize(width: 400, height: 300), CGSize(width: 980, height: 800), CGSize(width: 1600, height: 1100)] {
            let size = controller.sizeThatFits(in: proposal)
            precondition(abs(size.width - 980) < 0.5, "Content width must remain 980pt for proposal \(proposal), got \(size)")
            precondition(abs(size.height - max(670, proposal.height)) < 0.5, "Height must retain its minimum and remain resizable, got \(size)")
            count += 2
        }
        print("\(count)/\(count) native content sizing checks passed")
    }
}
