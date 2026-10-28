import AppKit
import SwiftUI

struct WindowPreviewSetupView: View {
    @ObservedObject var model: WindowPreviewSetupModel
    let openSettings: () -> Void
    let restart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Window previews").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 16) {
                step("1", title: "Allow Screen & System Audio Recording", detail: "Enable HandyToolbelt in macOS Screen & System Audio Recording settings.", complete: model.hasScreenAccess)
                step("2", title: "Test one window preview", detail: "macOS may ask to “bypass the system private window picker” and directly access screen and audio. This lets HandyToolbelt request window images for the chooser. It captures images only, never audio.", complete: model.phase == .ready)
            }
            Divider()
            status
            if needsRecovery {
                HStack(spacing: 10) {
                    Button("Open System Settings…", action: openSettings)
                    Button("Restart HandyToolbelt", action: restart)
                }
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if model.phase == .ready {
                    Button("Done", action: model.dismiss).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: model.dismiss).keyboardShortcut(.cancelAction)
                    Button(primaryTitle, action: primaryAction)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.nativeWorkPending)
                }
            }
        }
        .padding(24).frame(width: 480)
        .background(Theme.editor)
        .graphiteTheme()
        .background(PreviewSetupWindowLifecycle(onHidden: model.dismiss, onWindowChanged: { window in
            model.presentationIsVisible = { [weak window] in
                guard let window else { return false }
                return window.isVisible && !window.isMiniaturized
                    && (window.sheetParent.map { $0.isVisible && !$0.isMiniaturized } ?? true)
            }
        }))
        .onDisappear { model.dismiss() }
    }
    private func step(_ number: String, title: String, detail: String, complete: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if complete { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.requirementFulfilled) }
                else { Text(number).font(.callout.weight(.semibold)).foregroundStyle(Theme.secondary) }
            }.frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private var status: some View {
        switch model.phase {
        case .introduction:
            Text("Test Preview captures one window from another app and immediately discards the image. macOS may ask again later; HandyToolbelt cannot predict when. You can cancel and keep switching with app icons.")
                .font(.callout).foregroundStyle(Theme.secondary)
        case .screenAccess:
            Text("Allow access, then return here for the separate Test Preview step. If access is already enabled, restart HandyToolbelt and check again.")
                .font(.callout).foregroundStyle(Theme.secondary)
        case .testPreview:
            Text("Screen Recording is enabled. Select Test Preview when you are ready for the separate macOS confirmation described above.")
                .font(.callout).foregroundStyle(Theme.secondary)
        case .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking a preview… Respond to any macOS access prompt.").font(.callout)
            }
        case .ready:
            Label("Preview access works. macOS may ask again later.", systemImage: "checkmark.circle")
                .font(.callout)
        case let .problem(message):
            Text(message).font(.callout).foregroundStyle(Theme.secondary).textSelection(.enabled)
        }
    }
    private var needsRecovery: Bool {
        switch model.phase { case .screenAccess, .problem: return true; default: return false }
    }
    private var primaryTitle: String {
        if model.nativeWorkPending { return "Checking…" }
        return model.phase == .introduction ? (model.hasScreenAccess ? "Test Preview" : "Start Setup") : (model.phase == .testPreview ? "Test Preview" : "Check Again")
    }
    private func primaryAction() {
        if model.phase == .introduction { model.start() } else { model.checkAgain() }
    }
}

/// Closing or minimizing the settings window ends the authorization session;
/// switching away for System Settings or a native permission alert does not.
private struct PreviewSetupWindowLifecycle: NSViewRepresentable {
    let onHidden: () -> Void
    let onWindowChanged: (NSWindow?) -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(onHidden: onHidden, onWindowChanged: onWindowChanged) }
    func updateNSView(_ nsView: ObserverView, context: Context) { nsView.onHidden = onHidden; nsView.onWindowChanged = onWindowChanged }
    final class ObserverView: NSView {
        var onHidden: () -> Void
        var onWindowChanged: (NSWindow?) -> Void
        private var observers: [NSObjectProtocol] = []
        init(onHidden: @escaping () -> Void, onWindowChanged: @escaping (NSWindow?) -> Void) { self.onHidden = onHidden; self.onWindowChanged = onWindowChanged; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged(window)
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let window else { return }
            for observed in [window, window.sheetParent].compactMap({ $0 }) {
                for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: observed, queue: .main) { [weak self] _ in self?.onHidden() })
                }
            }
        }
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    }
}
