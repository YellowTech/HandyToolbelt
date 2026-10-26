# Window activation validation

Run `swift Scripts/check-window-activation.swift` for deterministic integration checks of the production `WindowActivationCoordinator` used by `WindowCatalog.activate`. The harness replaces native calls, clock, and queue scheduling. It verifies the AppKit → AX foreground → main → raise → observed-focus sequence; delayed confirmation and bounded timeout; selected-window identity; restoration failure; cancellation and supersession; and the main/worker routing contract. It never activates an application, creates an event tap, or requests Accessibility permission.

These checks cannot establish whether macOS grants foreground activation, an AX provider implements its attributes correctly, hardware modifier release reaches the event tap, Spaces switch correctly, or a signed installed build has permission. In particular, a mocked rejected AppKit request followed by successful AX foreground is regression coverage of the recovery sequence, not proof of OS behavior.

## Complete application flows

`swift Scripts/check-window-switcher-flow.swift` exercises the production keyboard monitor, chooser model, activation coordinator, stack keyboard driver, and host chooser/suspension routing together. Its 35 checks include fast Option release during enumeration, queued navigation, same-app window identity, cancellation and reopen, vanished windows, stale completions, and held-key cleanup when stopping or disabling Gestures. Native catalogue enumeration, event posting/tap installation, panels, capture, and system effects are substituted. Sleep and session notifications exercise the real lifecycle paths without sleeping the Mac.

`swift Scripts/check-window-snap-pipeline.swift` exercises the production monitor from captured mouse metadata through worker resolution, coalescing, preview scheduling and commit. Its 18 checks include delayed lookup and early release, the first menu-bar-clamped drag, stale callbacks, cancellation, application changes, invalid movement and AX failures. One check repeats 100 cycles on the same monitor and verifies drained work and bounded diagnostics. Native event delivery and AX reads/writes are substituted.

## Real-device smoke checklist

Run separately, manually, on the actual signed installed release candidate with Accessibility permission. Keep at least two windows of a target application open and record macOS version, app version, target apps, and observed result. Confirm the focused title/window visually; a diagnostic acknowledgement is insufficient.

- From another application, hold Option, press Tab, select a target, and release Option. The selected window becomes key and receives typing. Repeat in reverse with Shift-Tab.
- Select each of two windows of the same application, including when that application is already frontmost. Confirm the selected window, rather than just the application, becomes key.
- Repeat with a minimized target, hidden application, and a target on another Space. Observe restoration and foreground activation.
- Switch to the HandyToolbelt main window and back. Confirm local activation works without querying the app's own AX provider and the UI remains responsive.
- Cancel with Escape, click another application while the chooser is open, and disable window switching with pending work. No delayed activation should steal focus afterward.
- Quickly issue a second selection while the first is pending. Only the newest selection may complete activation.
- Close a selected target or quit its application before confirmation. Reopen the chooser afterward and confirm recovery without stale selection.
- Revoke Accessibility permission and confirm failure is reported, then restore permission and verify switching again.
- Inspect activation diagnostics when a target refuses focus: success must follow observed matching application and selected window. An accepted AppKit call or successful AXRaise alone must not be reported as success. A refusal should finish within the bounded verification period rather than keep stealing focus.

The application flow is now covered deterministically; the physical Option-release steps above remain required release checks because OS event delivery and actual focus are not mocked in real use.
