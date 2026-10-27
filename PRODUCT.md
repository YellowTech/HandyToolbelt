# HandyToolbelt

<!-- impeccable:product-schema 1 -->

## Platform
Native macOS desktop utility.

## Stack
Swift, SwiftUI and Apple system frameworks. The user requests pure Swift and no external calls.

## Users
The Mac owner currently uses BetterTouchTool primarily for trackpad gestures and wants a focused alternative, plus lightweight switching between individual windows instead of macOS' app switching.

## Product Purpose
Provide a small suite of productivity tools sharing one menu-bar entry. The first modules map trackpad gestures to actions and switch between individual windows. Gestures can also invoke the window switcher. Priority gestures confirmed by the user: tip-tap left/right around a stationary finger (e.g. switch browser tabs), three/four-finger taps and clicks, and holding a corner finger as a modifier for other gestures.

## Capabilities and Constraints
Simple UI; deliberately small feature set. No third-party runtime dependencies, network services, or subprocess-based action execution. Preferences are local; manual JSON export/import supports any folder available in the native file picker, including iCloud Drive. There is no automatic configuration sync.

One Swift app hosts independently enabled Gestures, Switcher, Snapping, Overlays, Power, and Coffee modules. Disabled input modules stop listeners and background work. Each tool has one enable switch; quit the app to stop the suite. Start at login uses native macOS login-item registration, with OS approval state shown when needed. Window switching uses Accessibility enumeration and focus, and a nonactivating list or grid. Optional window snapshots use ScreenCaptureKit with separately granted Screen Recording access; the default list uses icons and titles without capture. Snapshots are bounded, held in memory only while choosing, and never delay switching. Keyboard presets and gesture actions share its scope and filters. Option–Tab is the initial default, with Command–Tab available as an explicit selection.

The independent Snapping tool offers optional drag snapping when native tiling is unavailable because displays share Spaces (or on macOS 14). The public Spaces-mode API gates availability; changing to separate Spaces stops the listener without erasing the preference. Scope stays small: halves, quarters, and fill, with a target outline and Escape cancellation. Chooser settings use fictional static windows to illustrate all four layout/preview combinations without screen capture. A shared preview-size setting controls the mockup and real list/grid thumbnails. The open settings window participates in the Dock, app switching, and the chooser; closing it returns the app to menu-bar-only mode. Its own window is enumerated and raised through main-thread AppKit only.

Overlays provides brief centered text, optional gesture recognition toasts, and progress toasts with named steps. It works independently of Gestures. Turning Overlays off hides feedback without stopping automations. Feedback never takes focus or captures pointer input. Shared gesture-toast and haptic defaults live in Gestures → Settings; each ordinary mapping may opt out of recognition toasts. The global preference only takes effect while Overlays is enabled. Existing CLI `display.*` commands and configuration keys retain their names for compatibility.

Coffee offers independent Prevent idle sleep and Keep display awake checkboxes in its tab and the menu bar. Native power assertions match `caffeinate -i` and `-d`, without launching those commands; the shared menu icon becomes a coffee cup while an assertion is held. Disabling Coffee releases assertions and resumes the current selections when enabled again. Selections reset on quit. Deliberate sleep and lid closure remain available.

A bundled Swift CLI is the shared interface for scripts and AI agents: discover the schema, inspect status and settings, validate and apply configuration, undo the last apply, display feedback, and run, inspect, or cancel saved automations. Configuration writes require the current revision and save before changing live state. The running app owns settings, permissions, and action execution; the CLI connects through a private local Unix socket. No MCP server, Shortcuts integration, embedded AI, or network service is needed. Users can choose their own AI client with shell access. CLI control defaults off, including on existing installations, and requires a persistent per-Mac opt-in in Settings → Automations & CLI that is excluded from settings transfer and CLI configuration. Opting in trusts scripts and agents running as the same macOS user to use the app’s permissions without individual approvals. Disabling closes the listener and drops queued commands; already-started actions and in-app automations can finish.

Saved automations run a bounded sequence of existing native actions and waits. A gesture or the CLI can start them. One runs at a time, with inspectable recent results. Cancellation stops waits and future steps; a native AppleScript already executing must return before cancellation completes. Automation definitions are editable as validated JSON in Settings or through the CLI.

Configurable application groups scope gestures to the focused app. Browsers, Editors, and Terminals are editable starting examples. A group-specific mapping overrides the same global gesture; ambiguous overlaps do not dispatch. Background apps do not activate a group.

The user normally gestures with the right hand; the line between fingers slopes upward from left to right. A gesture gym supports visual practice, adjustable detection parameters, and local calibration from real tip-tap samples. Trial settings must be testable before applying them to normal use. Gym trials suppress actions only while the Gestures Gym workspace is selected and HandyToolbelt is frontmost. Background apps use saved production settings even if the Gym remains selected.

## Product Principles
- Keep each tool small and useful alone; connect gestures to window actions.
- Make detection observable before executing actions.
- Prefer native macOS controls and terminology.
- Share menu-bar space and settings without keeping disabled tools running.

Tip-taps support one to three resting fingers and a tap on either side; the middle variant uses two resting fingers. Anchored swipes move one finger while one to three others stay down. These compose with corner holds, keyboard modifiers, app groups, and stacks. How-to demonstrations teach the selected gesture without entering the recognition or action pipeline. Force click uses native macOS stage 2 on a Force Touch trackpad; raw pressure remains a visual cue only. Native app clicks may also occur. Freehand shape recording remains outside the current scope.

## Open Decisions
HandyToolbelt is the suite name; internal package and settings identifiers retain SuperTrackpad for compatibility. Magic Mouse support is secondary and hardware-dependent. Corner modifiers exclude the held finger from the action gesture's finger count. Actual performance versus AltTab needs measurement.



Gesture stacks hold one corner contact to enter a scoped set of gestures. Start actions may hold Control, Command, Option, or Shift; the app releases owned keys automatically when the corner lifts or the session ends. Child gestures use the other fingers (tip-taps and tip-swipes use two to four additional fingers), and release actions run after automatic key release on every ending, including a disconnect or input error. Only one stack runs at a time, suppressing all other gesture mappings; stacks cannot nest. Start, child, and release phases support up to 32 actions, with up to 32 child gestures. Hold keys is available only in the start phase. Ordinary actions include Key press, System, AppleScript, Show Text, Automation, and Open App by bundle identifier.

Version 5 configuration adds `stacks`, `keyboardModifiers` requirements (`any` or an `exact` physical modifier set), and the `openApplication` action. Existing versions 1–4 migrate with empty stacks and unrestricted physical modifiers. Enabled stacks reserve their corner across overlapping device, app, and physical modifier scopes; ordinary corner mappings and other stacks must use disjoint scopes or modifiers. Disabled drafts report incomplete action warnings. App-specific ordinary mappings retain priority over Everywhere mappings.

Global Settings owns tool enable switches, permissions, Start at login, and local automation management. Gestures owns a Settings subtab; Switcher retains its settings in its own tab. New enabling of Gestures, Switcher, or Snapping requires Accessibility, including CLI apply; missing or revoked access preserves saved preferences and is shown as an unmet requirement. Clickable permission pills route to and highlight the matching Global Settings control. Screen & System Audio Recording access is shown separately from the explicit preview-capture test; opening settings must never start a capture or permission prompt.

Settings backup in Global Settings exports saved preferences, mappings, stacks, app groups, and automations. Import uses the same strict configuration decoder as the CLI, offers a review, and backs up the previous configuration locally before replacement. Permissions, Start at login, live Coffee selections, and unapplied Gym trials stay specific to the current Mac/session. File-provider I/O runs off the main thread with file coordination. Active stacks, automations, calibration, and unapplied Gym trials block imports; a stale review never overwrites newer changes.
