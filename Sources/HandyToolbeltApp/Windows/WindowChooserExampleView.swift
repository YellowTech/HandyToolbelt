import SwiftUI
import HandyToolbeltCore

/// A static illustration using the chooser's real rows. No window discovery or capture occurs here.
struct WindowChooserExampleView: View {
    let layout: WindowLayout
    let showsPreviews: Bool
    var gridScale: Double = 1
    var previewScale: Double = 1

    private static let items: [WindowItem] = [
        WindowItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, processID: -1, appName: "Browser", bundleIdentifier: "example.browser", title: "Planning"),
        WindowItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, processID: -1, appName: "Editor", bundleIdentifier: "example.editor", title: "Notes"),
        WindowItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, processID: -1, appName: "Files", bundleIdentifier: "example.files", title: "Projects")
    ]

    private var settings: WindowSwitcherSettings {
        var result = WindowSwitcherSettings()
        result.layout = layout
        result.showsPreviews = showsPreviews
        result.previewScale = previewScale
        result.gridScale = gridScale
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Layout preview · example windows")
                .font(.caption).foregroundStyle(Theme.secondary)
            GeometryReader { geometry in
                let width = layout == .grid ? 900 * WindowSwitcherSettings.validatedGridScale(gridScale) : geometry.size.width / 0.9
                let scale = min(0.9, geometry.size.width / width)
                WindowChooserContent(items: Array(Self.items.prefix(showsPreviews && (layout == .list || previewScale > 1) ? 2 : 3)), settings: settings, selectedID: Self.items[1].id,
                    isLoading: false, message: "", images: [:], hasPreviewPermission: true,
                    onChoose: { _ in }, onCancel: {}, onVisible: { _ in }, exampleMode: true,
                    iconProvider: { AnyView(ExampleWindowIcon(item: $0)) },
                    previewProvider: { AnyView(ExampleWindowThumbnail(item: $0)) })
                    .frame(width: width, height: 294 / scale)
                    .scaleEffect(scale, anchor: .topLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }.frame(height: 294)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Layout preview, example windows. \(layout.title) layout, \(showsPreviews ? "with" : "without") previews. Planning in Browser, Notes in Editor selected.")
    }
}

private struct ExampleWindowIcon: View {
    let item: WindowItem
    var body: some View {
        Image(systemName: item.appName == "Browser" ? "globe" : item.appName == "Editor" ? "doc.text" : "folder")
            .resizable().scaledToFit().padding(3)
            .foregroundStyle(Theme.secondary)
    }
}

/// Authored vector content with deliberately broad shapes instead of illegible placeholder text.
private struct ExampleWindowThumbnail: View {
    let item: WindowItem
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(0..<3) { _ in Circle().fill(Theme.secondary.opacity(0.45)).frame(width: 4, height: 4) }
                Spacer()
                Capsule().fill(Theme.secondary.opacity(0.16)).frame(width: 36, height: 4)
                Spacer()
            }.padding(7).background(Theme.field)
            HStack(alignment: .top, spacing: 8) {
                if item.appName == "Files" {
                    Rectangle().fill(Theme.secondary.opacity(0.12)).frame(width: 20)
                    HStack(spacing: 10) {
                        ForEach(0..<3) { _ in
                            Image(systemName: "folder.fill").resizable().scaledToFit()
                                .foregroundStyle(Theme.secondary.opacity(0.65))
                        }
                    }.padding(.top, 10)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.secondary.opacity(0.5)).frame(width: 46, height: 6)
                        ForEach(0..<3) { index in
                            RoundedRectangle(cornerRadius: 2).fill(Theme.secondary.opacity(0.2))
                                .frame(maxWidth: index == 2 ? 48 : .infinity).frame(height: 4)
                        }
                    }
                    if item.appName == "Browser" {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.secondary.opacity(0.12)).frame(width: 26)
                    }
                }
            }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(Theme.editor)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
