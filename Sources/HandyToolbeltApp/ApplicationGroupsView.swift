import SwiftUI
import AppKit
import HandyToolbeltCore

struct ApplicationGroupsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("App groups").font(.system(size: 25, weight: .semibold))

            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: Binding(get: { model.selectedGroupID }, set: { id in
                        if model.selectedGroupID != id { model.selectedGroupID = id }
                    })) {
                        ForEach(model.configuration.applicationGroups) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) { ApplicationGroupIcons(group: group); Text(group.displayName).fontWeight(.medium) }
                                Text("\(group.applications.count) apps · \(model.groupUseCount(group.id)) gestures")
                                    .font(.caption).foregroundStyle(Theme.secondary)
                            }.padding(.vertical, 6).tag(group.id)
                            .graphiteSelection(model.selectedGroupID == group.id)
                        }
                    }.listStyle(.plain).scrollContentBackground(.hidden).background(GraphiteListSelection()).background(Theme.chrome)
                    Button(action: model.addGroup) { Label("New Group", systemImage: "plus") }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }.frame(minWidth: 210, idealWidth: 235, maxWidth: 280)
                if let id = model.selectedGroupID,
                   let group = model.configuration.applicationGroups.first(where: { $0.id == id }) {
                    ApplicationGroupEditor(model: model, group: Binding(get: {
                        model.configuration.applicationGroups.first(where: { $0.id == id }) ?? group
                    }, set: model.updateGroup)).id(id)
                } else {
                    ContentUnavailableView {
                        Label("Group your apps", systemImage: "square.stack.3d.up")
                    } description: {
                        Text("Create a group, add apps, then choose it in a gesture’s Works in setting.")
                    } actions: { Button("New Group", action: model.addGroup) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

private struct ApplicationGroupEditor: View {
    @ObservedObject var model: AppModel
    @Binding var group: ApplicationGroup
    @State private var selectedAppID: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Group name").frame(width: 90, alignment: .leading)
                TextField("Group name", text: $group.name).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Group name")
            }

            HStack {
                HStack { Text("Applications").font(.headline); HelpHint("Group gestures apply while one of these apps is focused. Apps match by identity, even when renamed or moved.") }
                Spacer()
                Button("Add Apps…") { model.chooseApplications(for: group.id) }
                Menu("Add Running App") {
                    ForEach(model.runningApplications) { app in
                        Button { model.addApplication(app, to: group.id) } label: {
                            Label { Text(app.name) } icon: {
                                if let icon = ApplicationIconCache.shared.image(for: app.bundleIdentifier) {
                                    Image(nsImage: icon)
                                } else { Image(systemName: "app.dashed") }
                            }
                        }
                            .disabled(group.applications.contains { $0.id == app.id })
                    }
                }.fixedSize()
            }
            List(selection: $selectedAppID) {
                ForEach(group.applications) { app in
                    HStack(spacing: 12) {
                        ApplicationIcon(bundleIdentifier: app.bundleIdentifier)
                        Text(app.name).fontWeight(.medium).help(app.bundleIdentifier)
                        Spacer()
                    }.padding(.vertical, 5).tag(app.id)
                    .graphiteSelection(selectedAppID == app.id)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).background(GraphiteListSelection()).background(Theme.field).clipShape(RoundedRectangle(cornerRadius: 12)).overlay {
                if group.applications.isEmpty {
                    VStack(spacing: 7) {
                        Text("Add your first app").font(.headline)
                        Text("This group will stay inactive until it contains an app.")
                            .font(.callout).foregroundStyle(Theme.secondary)
                    }.padding().allowsHitTesting(false)
                }
            }.frame(minHeight: 130)
            HStack {
                Button("Remove App", systemImage: "minus") {
                    group.applications.removeAll { $0.id == selectedAppID }
                    selectedAppID = nil
                }.disabled(selectedAppID == nil)
                Spacer()

            }
            Divider()
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.groupUseCount(group.id) == 0 ? "Choose this group in a gesture’s Works in setting." :
                         "Used by \(model.groupUseCount(group.id)) gestures. Reassign those before deleting this group.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("Delete Group", role: .destructive) { model.removeGroup(group.id) }
                    .disabled(model.groupUseCount(group.id) > 0)
            }
        }.padding(24).frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ApplicationIcon: View {
    let bundleIdentifier: String
    var size: CGFloat = 30
    var body: some View {
        if let icon = ApplicationIconCache.shared.image(for: bundleIdentifier) {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed").font(.system(size: size * 0.8)).frame(width: size, height: size)
                .foregroundStyle(Theme.secondary).help("Not installed on this Mac")
                .accessibilityLabel("Not installed")
        }
    }
}

struct ApplicationGroupIcons: View {
    let group: ApplicationGroup
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(group.applications.prefix(3))) { app in
                ApplicationIcon(bundleIdentifier: app.bundleIdentifier, size: 16)
            }
        }.accessibilityHidden(true)
    }
}

/// Cache misses as well as icons so unavailable apps never repeat Launch Services
/// lookups during gesture feedback updates. Workspace changes clear the bounded cache.
private final class ApplicationIconCache {
    static let shared = ApplicationIconCache()
    private final class Entry: NSObject {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }
    private let cache = NSCache<NSString, Entry>()
    private var observers: [NSObjectProtocol] = []
    private init() {
        cache.countLimit = 256
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.cache.removeAllObjects() })
        }
    }
    func image(for bundleIdentifier: String) -> NSImage? {
        let key = bundleIdentifier as NSString
        if let entry = cache.object(forKey: key) { return entry.image }
        let runningIcon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.icon
        let image = runningIcon ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map {
            NSWorkspace.shared.icon(forFile: $0.path)
        }
        cache.setObject(Entry(image), forKey: key)
        return image
    }
    deinit { for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
}
