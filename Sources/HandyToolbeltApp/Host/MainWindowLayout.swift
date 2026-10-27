import SwiftUI

/// Native content constraints keep the navigation and gesture workspaces stable,
/// while allowing the user to resize vertically.
enum MainWindowLayout {
    static let width: CGFloat = 980
    static let minimumHeight: CGFloat = 670
    static let defaultHeight: CGFloat = 800
}

extension View {
    func mainWindowContentSize() -> some View {
        frame(minWidth: MainWindowLayout.width, idealWidth: MainWindowLayout.width,
              maxWidth: MainWindowLayout.width, minHeight: MainWindowLayout.minimumHeight,
              idealHeight: MainWindowLayout.defaultHeight, maxHeight: .infinity)
    }
}
