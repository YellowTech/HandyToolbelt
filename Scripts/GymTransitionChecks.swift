// Development-only rendered native workspace and module benchmark. Never starts the host or global inputs.
import AppKit
import SwiftUI
import HandyToolbeltCore
@main struct GymTransitionChecks {
 @MainActor static func main() {
 setbuf(stdout, nil)
 _ = NSApplication.shared
 let url = FileManager.default.temporaryDirectory.appendingPathComponent("gym-timing-\(UUID()).json")
 defer { try? FileManager.default.removeItem(at: url) }
 let model = AppModel(storage: ConfigurationStore(url: url))
 let host = ProductivityModel(trackpad: model, display: DisplayModel(presenter: nil, observeSession: false), controlServerEnabled: false)
 let view = NSHostingView(rootView: ContentView(host: host, model: model))
 let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 980,height: 800),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
 window.isReleasedWhenClosed = false; window.contentView = view
 func render() { view.layoutSubtreeIfNeeded(); view.displayIfNeeded() }
 render()
 checkWorkspacePicker(view: view, host: host, model: model)
 for i in 0..<6 {
 let t = CFAbsoluteTimeGetCurrent(); model.selectWorkspace(i % 2 == 0 ? .gym : .mappings); let m = CFAbsoluteTimeGetCurrent()
 render(); let r = CFAbsoluteTimeGetCurrent()
 RunLoop.current.run(until: Date(timeIntervalSinceNow:0.02)); render()
 let sizingStart = CFAbsoluteTimeGetCurrent()
 let fitting = view.fittingSize
 let sizing = (CFAbsoluteTimeGetCurrent() - sizingStart) * 1000
 print("fitting \(fitting) sizing=\(sizing) ms")
 print("switch \(i) model=\((m-t)*1000) render=\((r-m)*1000) settled=\((CFAbsoluteTimeGetCurrent()-t)*1000) ms")
 }
 checkCachedEditor(view: view, model: model)
 checkStableReadout()
 checkTeachingPreview()
 checkCacheLifecycle(window: window, model: model)
 checkModuleTransitions()
 window.close()
 print("Native Gym layout and lifecycle regressions passed")
 }
 @MainActor static func checkWorkspacePicker(view: NSView, host: ProductivityModel, model: AppModel) {
   func settle() { view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)); view.layoutSubtreeIfNeeded() }
   model.configuration.trackpadModuleEnabled = true
   settle()
   guard let picker = nativeDescendants(view, NSSegmentedControl.self).first(where: {
     control in (0..<control.segmentCount).contains { control.label(forSegment: $0) == TrackpadWorkspace.gym.title }
   }) else { preconditionFailure("Workspace segmented control is available") }
   for target in [TrackpadWorkspace.gym, .groups, .settings, .mappings] {
     guard let index = (0..<picker.segmentCount).first(where: { picker.label(forSegment: $0) == target.title }) else { preconditionFailure("Workspace segment exists") }
     let previous = model.workspace
     picker.selectedSegment = index
     picker.sendAction(picker.action, to: picker.target)
     precondition(model.workspace == previous, "Picker routing does not publish inside the native control transaction")
     settle()
     precondition(model.workspace == target, "Native workspace control routes to its selected page")
   }
   for target in [InputDevice.magicMouse, .trackpad] {
     guard let devicePicker = nativeDescendants(view, NSSegmentedControl.self).first(where: { control in
       (0..<control.segmentCount).contains { control.label(forSegment: $0) == InputDevice.magicMouse.title }
     }), let index = (0..<devicePicker.segmentCount).first(where: { devicePicker.label(forSegment: $0) == target.title }) else { preconditionFailure("Device segmented control is available") }
     let previous = model.selectedDevice
     devicePicker.selectedSegment = index
     devicePicker.sendAction(devicePicker.action, to: devicePicker.target)
     precondition(model.selectedDevice == previous, "Device Picker does not publish inside the native control transaction")
     settle()
     precondition(model.selectedDevice == target, "Native device control routes to its selected device")
   }
   let devicePending = GestureControlSelection()
   devicePending.scheduleDevice(.magicMouse, host: host, model: model)
   devicePending.scheduleDevice(.trackpad, host: host, model: model)
   settle()
   precondition(model.selectedDevice == .trackpad, "Rapid device choices preserve the latest destination")
   devicePending.scheduleDevice(.magicMouse, host: host, model: model)
   devicePending.cancel(); settle()
   precondition(model.selectedDevice == .trackpad, "Explicit cancellation rejects a queued device choice")
   let pending = GestureControlSelection()
   pending.schedule(.gym, host: host, model: model)
   pending.cancel(); settle()
   precondition(model.workspace == .mappings, "Explicit cancellation rejects the queued workspace choice")
   pending.schedule(.gym, host: host, model: model)
   pending.schedule(.groups, host: host, model: model)
   settle()
   precondition(model.workspace == .groups, "Rapid control choices preserve the latest destination")
   model.selectWorkspace(.mappings)
   pending.schedule(.gym, host: host, model: model)
   pending.schedule(.mappings, host: host, model: model)
   settle()
   precondition(model.workspace == .mappings, "Returning to the current tab cancels an earlier queued choice")
   pending.schedule(.gym, host: host, model: model)
   host.section = .display; settle()
   precondition(model.workspace == .mappings, "Queued choices cannot enter Gym after leaving Gestures")
   host.section = .trackpad
   pending.schedule(.gym, host: host, model: model)
   model.configuration.trackpadModuleEnabled = false; settle()
   precondition(model.workspace == .mappings, "Queued choices cannot revive a disabled module")
   model.configuration.trackpadModuleEnabled = true
   pending.schedule(.gym, host: host, model: model)
   model.selectWorkspace(.settings); settle()
   precondition(model.workspace == .settings, "A direct model route supersedes an older queued control choice")
   model.selectWorkspace(.mappings)
   print("Native workspace Picker defers publication; latest-choice, hidden, disabled and direct-routing regressions passed")
 }
 @MainActor static func nativeDescendants<T: NSView>(_ node: NSView, _: T.Type) -> [T] {
   (node as? T).map { [$0] } ?? node.subviews.flatMap { nativeDescendants($0, T.self) }
 }
 @MainActor static func accessibleElements(_ node: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
   guard depth < 30, let element = node as? any NSAccessibilityProtocol else { return [] }
   return [element] + (element.accessibilityChildren() ?? []).flatMap { accessibleElements($0, depth: depth + 1) }
 }
 @MainActor static func selectPreviewMode(_ title: String, in root: NSView) {
   let controls = nativeDescendants(root, NSSegmentedControl.self)
   if let control = controls.first(where: { control in
     (0..<control.segmentCount).contains { control.label(forSegment: $0) == "How to" }
   }), let index = (0..<control.segmentCount).first(where: { control.label(forSegment: $0) == title }) {
     control.selectedSegment = index
     control.sendAction(control.action, to: control.target)
     return
   }
   guard let segment = accessibleElements(root).first(where: { $0.accessibilityLabel() == title && $0.accessibilityRole() == .radioButton }) else {
     preconditionFailure("The real How to / Live segmented control must remain available")
   }
   precondition(segment.accessibilityPerformPress(), "The preview segment accepts an explicit selection")
 }
 @MainActor static func checkTeachingPreview() {
   let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
   window.isReleasedWhenClosed = false
   defer { window.contentView = nil; window.close() }
   // Replay/Stop is exercised in the installed app. Standalone SwiftUI hosts
   // do not expose their virtual buttons through NSAccessibility in this runner.
   // Disabled imported drafts may contain hostile counts. Render both sizes for
   // every family rather than feeding any synthetic input to the recognizer.
   for count in [Int.min, -1, 0, 99, Int.max] {
     for kind in GestureKind.allCases {
       let spec = GestureSpec(kind: kind, fingers: count, corner: .topLeft)
       let glyphs = NSHostingView(rootView: VStack {
         GestureGlyph(gesture: spec).frame(width: 40, height: 28)
         GestureHowTo(gesture: spec).frame(width: 560)
       }.frame(width: 600, height: 160))
       window.contentView = glyphs
       glyphs.layoutSubtreeIfNeeded()
       if let bitmap = glyphs.bitmapImageRepForCachingDisplay(in: glyphs.bounds) {
         glyphs.cacheDisplay(in: glyphs.bounds, to: bitmap)
       }
       precondition(glyphs.fittingSize.height.isFinite, "Extreme draft counts produce finite teaching geometry")
     }
   }
   print("Extreme draft teaching geometry renders safely in compact and instructional sizes")
 }
 @MainActor static func checkModuleTransitions() {
   let url = FileManager.default.temporaryDirectory.appendingPathComponent("module-timing-\(UUID()).json")
   defer { try? FileManager.default.removeItem(at: url) }
   let model = AppModel(storage: ConfigurationStore(url: url))
   var timerStarts = 0, timerStops = 0
   let power = PowerModel(driver: .init(read: { PowerReading(batteryPresent: true) }, observe: { _ in {} }),
     scheduler: .init(repeatEvery: { _, _ in timerStarts += 1; return { timerStops += 1 } }),
     isFrontmost: { true }, observeLifecycle: false)
   let host = ProductivityModel(trackpad: model, display: DisplayModel(presenter: nil, observeSession: false), power: power, controlServerEnabled: false)
   model.configuration.trackpadModuleEnabled = true
   model.configuration.windowSwitcher.isEnabled = true
   model.configuration.powerModuleEnabled = true
   let binding = GestureBinding(gesture: .init(kind: .tap), action: .init(kind: .showText, text: "MODULE-EDITOR"), isEnabled: false)
   model.configuration.bindings = [binding]; model.selectedID = binding.id
   host.section = .display
   let root = NSHostingView(rootView: ProductivityView(host: host, trackpad: model, windows: host.windows))
   let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
   window.isReleasedWhenClosed = false; window.contentView = root
   defer { window.contentView = nil; window.close() }
   func render() {
     root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
     RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
     root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
   }
   func descendants<T: NSView>(_ node: NSView, _: T.Type) -> [T] {
     (node as? T).map { [$0] } ?? node.subviews.flatMap { descendants($0, T.self) }
   }
   func texts() -> [String] { descendants(root, NSTextField.self).map(\.stringValue) }
   var mappingsLive = false
   let benchmarkOnly = ProcessInfo.processInfo.arguments.contains("--benchmark-only")
   host.section = .display; render()
   var cachedModule: NSView?, cachedWorkspaces: WorkspaceHostingSurface.Container?
   var workspaceHosts: [TrackpadWorkspace: NSView] = [:]
   for workspace in TrackpadWorkspace.allCases {
     model.selectWorkspace(workspace); render()
     if workspace == .settings { precondition(descendants(root, TouchDisplayClock.DisplayClockView.self).isEmpty, "Gesture Settings has no visualization clock") }
     for attempt in 0..<4 {
       host.section = .display; render()
       if !benchmarkOnly, let cachedModule {
         precondition(cachedModule.window == nil && cachedModule.superview == nil, "Hidden module leaves window, native input and AX tree")
         let clocks = descendants(cachedModule, TouchDisplayClock.DisplayClockView.self)
         if workspace == .gym || (workspace == .mappings && mappingsLive) {
           precondition(!clocks.isEmpty, "Live Gestures content retains its nested clock")
         } else {
           precondition(clocks.isEmpty, "How to and nonvisual workspaces have no touch sampling clock")
         }
         precondition(clocks.allSatisfy { !$0.isSampling && $0.window == nil }, "Nested clocks stop when the module detaches")
         model.touchVisualization.submit(GymSnapshot(contacts: [Contact(id: 1, x: 0.2, y: 0.3)]), deviceID: 1, at: ProcessInfo.processInfo.systemUptime)
         precondition(clocks.allSatisfy { !$0.isSampling }, "Input cannot wake a detached module clock")
       }
       let start = CFAbsoluteTimeGetCurrent()
       host.section = .trackpad
       let mutated = CFAbsoluteTimeGetCurrent()
       render()
       print("Native module Display→Gestures/\(workspace.rawValue) #\(attempt) model=\((mutated-start)*1000) settled=\((CFAbsoluteTimeGetCurrent()-start)*1000) ms (includes 20 ms run-loop drain)")
       if !benchmarkOnly {
         let modules = descendants(root, ModuleHostingSurface.Container.self)
         precondition(modules.count == 1 && modules[0].subviews.count == 1, "Exactly one module is attached")
         let module = modules[0].subviews[0]
         let nested = descendants(module, WorkspaceHostingSurface.Container.self)
         precondition(nested.count == 1 && nested[0].subviews.count == 1, "Gestures has exactly one attached workspace")
         if let cachedModule { precondition(module === cachedModule, "Returning to Gestures retains the native module") }
         if let cachedWorkspaces { precondition(nested[0] === cachedWorkspaces, "Top-level navigation retains the entire nested workspace cache") }
         if let previous = workspaceHosts[workspace] { precondition(nested[0].subviews[0] === previous, "Workspace native identity survives module navigation") }
         cachedModule = module; cachedWorkspaces = nested[0]; workspaceHosts[workspace] = nested[0].subviews[0]
         if workspace == .mappings {
           precondition(texts().contains("MODULE-EDITOR"), "Route renders a real enabled mapping editor")
           if !mappingsLive {
             precondition(descendants(module, TouchDisplayClock.DisplayClockView.self).isEmpty, "Mappings defaults to How to without a touch clock")
             selectPreviewMode("Live", in: module)
             render()
             precondition(!descendants(module, TouchDisplayClock.DisplayClockView.self).isEmpty, "Explicit Live mode attaches the real touch clock")
             selectPreviewMode("How to", in: module)
             render()
             precondition(descendants(module, TouchDisplayClock.DisplayClockView.self).isEmpty, "Returning to How to removes the live touch clock")
             selectPreviewMode("Live", in: module)
             render()
             mappingsLive = true
           }
         }
       }
     }
   }
   guard !benchmarkOnly else { return }
   for workspace in TrackpadWorkspace.allCases {
     model.selectWorkspace(workspace); render()
     precondition(cachedWorkspaces!.subviews[0] === workspaceHosts[workspace], "All nested workspaces survive top-level detachment")
   }
   model.selectWorkspace(.mappings); render()
   model.isRecordingShortcut = true
   let fields = descendants(root, NSTextField.self).filter { $0.isEditable }
   if let field = fields.first { window.makeFirstResponder(field) }
   host.section = .display
   precondition(!model.isRecordingShortcut && !model.isSelected, "Leaving the top-level Gestures module immediately ends shortcut recording")
   render()
   if let responder = window.firstResponder as? NSView {
     precondition(!responder.isDescendant(of: cachedModule!), "Detached controls cannot keep keyboard focus")
   }
   let mouse = GestureBinding(device: .magicMouse, gesture: .init(kind: .tap, fingers: 2), action: .init(kind: .showText, text: "HIDDEN-MOUSE-EDIT"), isEnabled: false)
   model.configuration.bindings.append(mouse)
   model.selectDevice(.magicMouse)
   render()
   host.section = .trackpad; render()
   precondition(texts().contains("HIDDEN-MOUSE-EDIT") && !texts().contains("MODULE-EDITOR"), "Returning module reflects device, selection and configuration edits made while hidden")
   model.practice(.init(kind: .swipeLeft, fingers: 3)); render()
   model.selectedID = binding.id
   precondition(model.gymGesture == binding.gesture, "Active Gym selection immediately adopts its mapping's gesture")
   model.gymGesture = .init(kind: .swipeLeft, fingers: 3)
   let practice = model.gymGesture
   host.section = .display; render()
   model.selectedID = mouse.id; render()
   precondition(model.gymGesture == practice, "Detached Gestures selection observers do not replace the practice target")
   host.section = .trackpad; render()
   precondition(model.showGym && model.gymGesture == practice, "Returning to Gym preserves its practice target")
   model.startCalibration()
   precondition(model.isCalibrating, "Calibration fixture starts")
   host.section = .display
   precondition(!model.isCalibrating, "Leaving the module ends calibration")
   render()
   model.configuration.trackpadModuleEnabled = false; render()
   host.section = .trackpad; render()
   precondition(descendants(root, WorkspaceHostingSurface.Container.self).isEmpty, "Disabled hidden module replaces its workspaces with the off hint")
   host.section = .settings; render()
   model.configuration.trackpadModuleEnabled = true; render()
   host.section = .trackpad; render()
   precondition(descendants(root, WorkspaceHostingSurface.Container.self).count == 1, "Re-enabling a hidden module restores live content")
   // Exercise the real Power view lifecycle with a fake driver; never host.start().
   power.configure(enabled: true, running: true)
   host.section = .power; render()
   precondition(power.isLive && timerStarts == 1, "Showing Power starts visible polling")
   host.section = .display; render()
   precondition(!power.isLive && timerStops == 1, "Detaching cached Power stops polling")
   host.section = .power; render()
   precondition(power.isLive && timerStarts == 2, "Reattaching cached Power resumes polling")
   host.section = .settings; render()
   precondition(!power.isLive && timerStops == 2, "Switching modules stops Power polling")
   var disabledWindows = host.windows.settings; disabledWindows.isEnabled = false
   host.windows.configure(disabledWindows)
   precondition(!host.windows.isRunning && !host.windows.settings.isEnabled, "Preview fixture keeps Windows disabled")
   host.windows.previewSetup.present(); render()
   host.windows.configure(disabledWindows); render()
   precondition(!host.windows.isRunning && !host.windows.settings.isEnabled, "Unrelated config does not start Windows")
   precondition(host.windows.previewSetup.isPresented, "Unrelated configure while Windows is off retains explicit setup")
   precondition(host.windows.previewSetup.isPresented, "Preview setup fixture is presented without capture or global input")
   host.section = .display; render()
   precondition(!host.windows.previewSetup.isPresented, "Leaving Global Settings dismisses preview setup")
   host.section = .trackpad; model.selectWorkspace(.mappings); render()
   // Disabling the module replaced its content, so the new preview defaults
   // to How to. Explicitly restore Live before checking closed-window clocks.
   selectPreviewMode("Live", in: root); render()
   precondition(!descendants(root, TouchDisplayClock.DisplayClockView.self).isEmpty, "Closed-window fixture starts with a real Live clock")
   let retainedModule = descendants(root, ModuleHostingSurface.Container.self)[0].subviews[0]
   let retainedWorkspace = descendants(root, WorkspaceHostingSurface.Container.self)[0].subviews[0]
   window.close(); window.contentView = nil
   precondition(retainedModule.window == nil, "Closing and releasing the native content detaches cached modules")
   let closedClocks = descendants(retainedModule, TouchDisplayClock.DisplayClockView.self)
   precondition(!closedClocks.isEmpty && closedClocks.allSatisfy { !$0.isSampling }, "Removing closed-window content stops nested clocks")
   model.configuration.bindings[1].action.text = "REOPENED-MOUSE-EDIT"
   window.contentView = root; render()
   precondition(descendants(root, ModuleHostingSurface.Container.self)[0].subviews[0] === retainedModule && descendants(root, WorkspaceHostingSurface.Container.self)[0].subviews[0] === retainedWorkspace, "Reattaching retained window content preserves module and workspace identity")
   precondition(texts().contains("REOPENED-MOUSE-EDIT"), "Reattached window renders edits made after closing")
   print("Native module identity, nested cache, hidden clocks/input/AX detachment, live editor, disabled module, Gym, Power, preview and retained-window lifecycle regressions passed")
 }
 @MainActor static func checkCachedEditor(view: NSView, model: AppModel) {
   let first = GestureBinding(gesture: .init(kind: .tap), action: .init(kind: .showText, text: "FIRST-CACHED-EDITOR"), isEnabled: false)
   let second = GestureBinding(gesture: .init(kind: .tap, fingers: 4), action: .init(kind: .showText, text: "SECOND-CACHED-EDITOR"), isEnabled: false)
   let mouse = GestureBinding(device: .magicMouse, gesture: .init(kind: .tap, fingers: 2), action: .init(kind: .showText, text: "MOUSE-CACHED-EDITOR"), isEnabled: false)
   model.configuration.bindings = [first, second, mouse]
   model.selectWorkspace(.mappings)
   func texts(_ node: NSView) -> [String] {
     (node as? NSTextField).map { [$0.stringValue] } ?? node.subviews.flatMap(texts)
   }
   func settle() { view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)); view.layoutSubtreeIfNeeded() }
   model.selectedID = first.id; settle()
   precondition(texts(view).contains("FIRST-CACHED-EDITOR"), "Cached mappings must reflect current configuration")
   model.selectedID = second.id; settle()
   precondition(texts(view).contains("SECOND-CACHED-EDITOR") && !texts(view).contains("FIRST-CACHED-EDITOR"), "Cached mappings must change the selected editor")
   model.selectDevice(.magicMouse); settle()
   precondition(texts(view).contains("MOUSE-CACHED-EDITOR") && !texts(view).contains("SECOND-CACHED-EDITOR"), "Cached mappings must change the device editor")
   model.isRecordingShortcut = true; model.selectWorkspace(.gym); settle()
   precondition(!model.isRecordingShortcut, "Leaving cached mappings ends shortcut recording")
   print("Cached mapping selection, configuration and device refresh passed")
 }
 @MainActor static func checkStableReadout() {
   let readout = GymReadout()
   let history = GymHistory()
   for width in [480.0, 570.0] {
     let diagnostics = NSHostingView(rootView: GymDetectionReadout(readout: readout, tuning: GestureTuning(), target: .init(kind: .tipTapLeft)).frame(width: width).fixedSize(horizontal: false, vertical: true))
     let attempts = NSHostingView(rootView: GymAttemptsView(history: history).frame(width: width).fixedSize(horizontal: false, vertical: true))
     var expectedReadout: CGFloat?, expectedAttempts: CGFloat?
     for count in [0, 1, 5] {
       var next = GymSnapshot()
       next.contacts = (0..<count).map { Contact(id: $0, x: 0.2, y: 0.3) }
       next.deviceName = String(repeating: "Long device name ", count: 8)
       if count == 5 { next.feedback.message = String(repeating: "A longer recognition explanation. ", count: 15) }
       readout.update(next)
       diagnostics.layoutSubtreeIfNeeded()
       RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
       let height = diagnostics.fittingSize.height
       if let expectedReadout { precondition(abs(height - expectedReadout) < 1, "Readout height changes with contacts or feedback") }
       else { expectedReadout = height }
     }
     for count in [0, 1, 8] {
       history.attempts = (0..<count).map { _ in GymAttempt(message: String(repeating: "Long attempt ", count: 12), matched: false, recognized: false) }
       attempts.layoutSubtreeIfNeeded()
       RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
       let height = attempts.fittingSize.height
       if let expectedAttempts { precondition(abs(height - expectedAttempts) < 1, "Attempt viewport height changes with history") }
       else { expectedAttempts = height }
     }
     print("Stable readout/history heights at width \(width): \(expectedReadout!) / \(expectedAttempts!)")
   }
 }
 @MainActor static func checkCacheLifecycle(window: NSWindow, model: AppModel) {
   let container = WorkspaceHostingSurface.Container()
   container.frame = NSRect(x: 0, y: 0, width: 980, height: 500)
   window.contentView = container
   var appearances = 0, disappearances = 0
   func content(_ workspace: TrackpadWorkspace) -> AnyView {
     AnyView(VStack { Text(workspace.title); TouchDisplayClock(visualization: model.touchVisualization).frame(height: 1) }
       .onAppear { appearances += 1 }.onDisappear { disappearances += 1 })
   }
   func clocks(_ view: NSView) -> [TouchDisplayClock.DisplayClockView] {
     (view as? TouchDisplayClock.DisplayClockView).map { [$0] } ?? view.subviews.flatMap(clocks)
   }
   container.select(.mappings, content: content); container.layoutSubtreeIfNeeded()
   RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
   let original = container.subviews[0]
   let oldClocks = clocks(original)
   precondition(!oldClocks.isEmpty, "Cached workspace creates a native display clock")
   container.select(.gym, content: content); container.layoutSubtreeIfNeeded()
   precondition(original.superview == nil && original.window == nil, "Inactive workspace leaves native event/AX tree")
   precondition(oldClocks.allSatisfy { !$0.isSampling && $0.window == nil }, "Detached clocks stop sampling")
   model.touchVisualization.submit(GymSnapshot(contacts: [Contact(id: 1, x: 0.2, y: 0.3)]), deviceID: 1, at: ProcessInfo.processInfo.systemUptime)
   precondition(oldClocks.allSatisfy { !$0.isSampling }, "Input cannot wake detached clocks")
   container.select(.mappings, content: content)
   precondition(container.subviews.count == 1 && container.subviews[0] === original, "Workspace returns the cached native view")
   RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
   precondition(appearances >= 3 && disappearances >= 2, "Cached native hosts preserve SwiftUI appearance/disappearance")
   container.removeFromSuperview(); window.contentView = nil
 }

}
