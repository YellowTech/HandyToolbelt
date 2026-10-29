# HandyToolbelt release review

## Fast snapping with paced fallback — 0.30.7 (75), 2026-10-29

Reviewed [Rectangle's frame-adjustment handling](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AccessibilityElement.swift) and [Enhanced UI notes](https://github.com/rxhanson/Rectangle/blob/main/TerminalCommands.md#control-enhanced-ui-handling). HandyToolbelt independently implements a scoped fast attempt: inspect the target app's `AXEnhancedUserInterface`, temporarily disable it when needed, change the frame, and restore and verify the original mode immediately afterward. Unknown or unconfirmed mode changes use the paced path. VoiceOver and Switch Control keep paced handling; no permanent per-app accessibility policy is introduced.

The fast result is checked across spaced observations. Incorrect or overwritten results fall back to the existing move-first paced sequence, with bounded work and partial geometry retained. Cancellation still stops further frame writes while restoring any mode change already attempted. The fast path does not add an animation or a new user setting.

The full unit/contract suite passed, including 13 immediate-update policy tests and 45 snapping tests; 39 production-pipeline checks passed. Coverage includes immediate visible placement, a single fast attempt followed by paced recovery, coupled asynchronous updates, native failures, cancellation and lost eligibility at each write, stale geometry after a mode change, and verified restoration with bounded retries. Restoration denied by macOS is recorded rather than retried indefinitely. The user confirmed that snapping is much faster and works on this Mac; fallback behavior has automated coverage but has not been deliberately forced in a physical test.

Release compilation and strict signature verification passed. Installed and restarted 0.30.7 with matching candidate executables, one app process, unchanged settings and signing requirement, and the Snapping page available. Rollback: `.build/install-backups/2026-10-29T21-04-35Z`.

## Recognize delayed window movement near the menu bar — 0.30.6 (74), 2026-10-29

The 0.30.5 recording showed successful top, left and right commits, but one down-then-up titlebar drag was rejected as `movement_not_proven`. Firefox's AX frame repeated and then jumped while pointer samples continued moving. Comparing only the latest or immediately adjacent samples missed the corresponding window translation.

Qualification now compares against a bounded history of at most 12 observations within 250 ms. The existing 8 pt minimum window translation, 12 pt displacement tolerance, unchanged-size requirement and menu-bar intent checks remain. The monitor injects monotonic time; stale, reversed and nonfinite timestamps cannot reuse older history. The snap application sequence is unchanged.

Numeric core and production replays fail before the change and pass afterward. Review also reproduced and fixed losing upward intent when qualification arrives after the window has already returned to the menu bar; actual upward movement is retained, but every target still requires a confirmed move. The full unit/contract suite passed, followed by 44 snapping tests and 34 production-pipeline checks after that final correction. Coverage preserves stationary-content, resize, stale-history and purely horizontal menu-bar rejection. Physical menu-bar dragging remains for user verification.

Release compilation and strict signature verification passed. Installed and restarted 0.30.6 with matching candidate executables, one app process, unchanged settings and signing requirement, and the Snapping page available. Rollback: `.build/install-backups/2026-10-29T19-46-59Z`.

## Settle window changes between snapping steps — 0.30.5 (73), 2026-10-29

The Firefox right-half trace showed successful size writes followed by a position correction that was then observed with the old width. Rapid changes to separate AX attributes could overwrite the other part of an in-flight frame change. Snapping now separates move, resize, and any necessary correction across scheduled observations. It still moves first, preserves partial results, and stops on cancellation or lost eligibility. Diagnostics call retained nonexact geometry a partial result rather than assuming a native constraint.

A numeric fixture with independently committed and optimistically reported geometry fails against 0.30.4 and passes with paced effects. Coverage includes varied native delays, chronological production scheduling, cancellation with native work already pending, already-exact geometry without setters, and bounded unstable readbacks. The full unit/contract suite passed, including 39 snapping tests; 33 production-pipeline checks passed. Three stable 100 ms observations separate each changed attribute. This is bounded settling based on AX readbacks, not an authoritative native animation-completion signal; a physical Firefox retest is still needed.

Release compilation and strict signature verification passed. Installed and restarted 0.30.5 with matching candidate executables, one app process, unchanged settings and signing requirement, and the Snapping page available. Rollback: `.build/install-backups/2026-10-29T19-32-17Z`.

## Retain best-effort snaps — 0.30.4 (72), 2026-10-29

Snapping now moves first, resizes, then corrects the position if the old window size constrained the initial move. It makes at most three target applications and never writes the original frame back. Exact results require two spaced matching observations; a stable changed frame retained after a constraint or setter failure is reported separately as `constrained_result_retained`. Cancellation, lost eligibility, unreadable geometry, or exhausted verification stops further work without restoring the window.

The full unit/contract suite passed, followed by 35 snapping tests and 31 production-pipeline checks after review. Review added a strict observation bound for alternating exact/nonexact frames, retained minimum-height geometry with position clamping, and cancellation during correction/readback. The three numeric cases from the work-laptop trace still pass. The affected work laptop still needs a physical drag test.

Release compilation and strict signature verification passed. Installed and restarted 0.30.4; both executables match the signed candidate, one app process is running, settings and the signing requirement are unchanged, and the Snapping page opens. Rollback: `.build/install-backups/2026-10-29T19-19-24Z`.

## Position-constrained snapping — 0.30.3 (71), 2026-10-29

The work-laptop trace exposed a transaction-order bug: resizing at the old origin was constrained to the remaining display width or height, and the size mismatch prevented any position change. Snapping now applies both size and position and uses bounded, spaced corrections before judging the final rectangle. Two matching observations still establish success. Genuine constraints or partial setter failures trigger bounded best-effort restoration of the original frame; cancellation, lost eligibility, and unreadable state stop further writes.

Three numeric fixtures reproduce the trace's two full-screen and one left-half failure on an external display above the primary. They fail against the previous implementation and pass with the correction in both core and production-pipeline checks. Additional coverage exercises delayed size readbacks, position clamping, native drag rollback, actual size limits, partial setter failure, and cancellation or permission loss during restoration. The original user log remains outside the repository.

Review added terminal failure handling, accurate application counts, no redundant restoration when the original frame is already restored, and a minimum-height case requiring both restoration passes. The full unit/contract suite passed, followed by 34 focused snapping tests and 30 production-pipeline checks on the final transaction. Release compilation and strict signature verification passed. Installed and restarted 0.30.3 with matching candidate binaries, unchanged settings and signing requirement, and the Snapping page available. Rollback: `.build/install-backups/2026-10-29T19-01-09Z`. The affected work laptop still needs a physical drag test.

## Wider tip-tap edge exclusion — 0.30.2 (70), 2026-10-28

The default resting-finger edge deadzone increases from 4% to 6%. A regression uses rounded geometry from a reported near-rim accidental tip-tap: the old threshold accepts it, the new default rejects it, and a slightly inset anchor still works. Existing saved tuning remains respected; the user's current trackpad setting is explicitly updated to 6% during this installation.

The full unit/contract suite and release build passed, including the new near-rim regression. Installed-app inspection confirmed 6.0% in Gesture Gym, with no unapplied changes. Both executables match the signed candidate, one 0.30.2 process is running, and the only saved configuration change is the requested trackpad deadzone. Rollback: `.build/install-backups/2026-10-28T20-01-19Z`.

## Nonmodal switcher failures — 0.30.1 (69), 2026-10-28

The chooser no longer publishes activation failures into the app's shared alert. Failed or cancelled focus attempts leave it dismissed and release the switching gate for the next invocation. Window system actions carry a typed failure through gesture and stack dispatch, which suppresses only their modal presentation while preserving failure results for CLI/automation and the existing activation diagnostics. Stack failure cleanup still releases owned modifiers. Settings recovery and unrelated errors keep their existing presentation.

Passed 68 switcher-flow checks, including failed-target and focus-change retry, permission/module failure classification, and stack modifier release. Release compilation and strict signature verification passed. Installed and restarted 0.30.1; the app window opens normally, both executables match the candidate, and the existing signing requirement and saved settings are preserved. Rollback: `.build/install-backups/2026-10-28T17-11-50Z`.

## Typing protection and diagnostic recording — 0.30.0 (68), 2026-10-28

Physical non-modifier key presses suppress gestures for 0.5 seconds, cancel pending recognition, and release active stacks. HandyToolbelt-generated keys and modifier-only transitions do not start the cooldown. Contacts held during typing must lift before rearming; stale, invalid, and suspended frames cannot clear that barrier.

Global Settings adds a session-only debug recorder, off by default. A bounded in-memory ring exports the last 15 seconds as local JSON after an explicit save. Exports include touch geometry, generic keyboard events, recognition decisions, sanitized tuning, and snapping coordinates, AX result codes, and frame readbacks. They exclude typed characters/key codes, app or window names, action contents, screenshots, and device names. Disabling clears the buffer; export freezes the interval before opening the save panel.

Preview capture now requires a successful explicit setup check and a versioned local acknowledgement of the direct-window permission explanation. Returning after the Screen Recording grant stops at Test Preview. Until setup completes, the chooser retains app-icon rows with an Open Setup action. The local acknowledgement does not claim a queryable or permanent macOS direct-capture grant.

The external-display failure remains unconfirmed. Four production-pipeline fixtures pass with displays left/right/above/below the primary display. The new trace records resolution, movement qualification, requested/readback frames, AX failures, and cancellation to diagnose a real failing drag. A fixture initially failed because it added a display after constructing the monitor; injecting screens before construction corrected the test, with no speculative geometry change. The temporal harness now uses a fresh model when moving from virtual timestamps to real-clock checks instead of rewinding an input session.

Validation passed: unit/contract tests, typing/recorder integration checks, 417 model/navigation checks and 418 legacy-model checks, 59 switcher-flow checks, 27 snapping-pipeline checks, 58 stack-runtime checks, 48 temporal-gesture checks, 52 native-click checks, release compilation, and strict signature verification. Installed-app review confirmed the setup explanation, successful explicit preview capture, recorder off by default, local JSON export, and disabled saving after recording was turned off. The exported sample uses relative timestamps within 15 seconds and only the expected diagnostic fields. Both installed executables match the signed candidate; the signing requirement and saved configuration are preserved, with one 0.30.0 process running. Rollback: `.build/install-backups/2026-10-28T16-41-33Z`.

## Folder interaction and change review — 0.29.2 (67), 2026-10-27

The stack disclosure now covers the arrow and folder with a 46 × 44 pt target and an accessible expanded/collapsed value. Review introduced typed sidebar identities, kept Add Gesture independent of folder selection, preserved selection when deleting unrelated mappings, and applied the existing name limit to folder names.

The window catalogue retains known live windows when an app temporarily fails Accessibility enumeration. Successful empty enumerations and explicit destruction still remove windows. Order-only refreshes preserve in-flight previews; delayed metadata copies matching geometry without overwriting newer window state.

Passed 140 unit/contract tests, 58 switcher-flow checks, 412 model/navigation checks and 413 legacy-model checks, release compilation, and strict signature verification. Installed-app checks confirmed expansion through the folder icon, collapse through its surrounding padding, child-to-folder selection fallback, and an unselected Add Gesture row. The running binaries match the candidate, signing requirements and saved settings are preserved, and 0.29.2 was restarted successfully. Rollback: `.build/install-backups/2026-10-27T22-01-31Z`.

## Switcher opening latency — 0.29.1 (66), 2026-10-27

The preview change still left every opening waiting for a full serial Accessibility scan. The chooser now uses a synchronized known-window snapshot immediately, then refreshes and merges results without changing the selected surviving window. Window/app events maintain the snapshot; focus events update per-process focus and recent order without full scans. Activation and preview metadata use independent queues and copied native references, so a background scan cannot hold confirmation. The first scan after enabling or resuming remains asynchronous.

Review addressed stale scan delivery after stop/start, changes arriving during scans, newer focus being overwritten, local-window reopening/activation, and minimized state changing between scans. Passed 25 focused Core tests, 51 switcher flow checks (including a blocked native scan queue), 54 activation checks, native main-window presence checks, and debug/release builds. Installed and relaunched with unchanged signing requirements and settings; Switcher permissions remain fulfilled. Physical opening latency still needs user confirmation. Rollback: `.build/install-backups/2026-10-27T21-49-35Z`.

## Stack folders and asynchronous previews — 0.29.0 (65), 2026-10-27

Stacks now expand into individually selectable child gestures. Folder settings retain activation and start/release actions; child editors support optional names and preserve ordered action sequences. Selection remains valid after collapse, deletion, device changes and configuration replacement. Existing configurations decode without child names.

The switcher publishes its window list before fetching preview geometry. Visible-window enrichment runs on a separate cancellable AX queue, while screenshots retain bounded concurrency and caching. Missing geometry for same-title peers prevents ambiguous image assignment. Confirming, dismissing or reopening rejects stale metadata and images.

Validation passed: 7 stack tests, 14 contract tests, 407 model/navigation checks in both invocations, preview matching coverage, 43 switcher flow checks, 58 stack runtime checks, release compilation and strict signature verification. Installed-app visual checks covered folder selection, expansion, child editors, collapse with a selected child, and the matching gesture demonstration. Physical switcher responsiveness remains for user testing; synthetic OS-boundary tests do not measure real-device latency.

Installed and restarted with the existing signing requirement and saved choices preserved; both running-bundle executables match the signed candidate. Rollback backup: `.build/install-backups/2026-10-27T21-33-03Z`.

## Main-window reopening — 0.28.3 (64), 2026-10-27

Fixed a reproduced case where native reopening of the retained main window left its switcher registration marked closed. Reconcile visibility only for the registered window, preserve its identity, and honor login-window suppression. The native regression uses the actual SwiftUI reader and nested cached hosts; it failed before the fix and now passes, including panel exclusion and close/reopen behavior. Existing hidden/minimized and deferred-policy checks also pass, as do 54 activation checks and the release build.

Installed and restarted 0.28.3 with the signing requirement and saved settings preserved; the running executable matches the signed candidate. The app-control tool confirmed the main window reopened. The user's entry had reappeared before installation, so this reproduced lifecycle defect is a plausible cause of that intermittent report, not a confirmed trace of their exact sequence. Backup: `.build/install-backups/2026-10-27T21-01-53Z`.

## Gesture names — 0.28.2 (63), 2026-10-27

Ordinary mappings support an optional name in the editor, saved list, live recognition label, and gesture toast. Blank names preserve previous labels; Gym teaching remains literal. Names round-trip through settings and the CLI. Visual review also caught stale nested list rows after edits; capturing current values fixes labels and selection without recreating row identities.

Validation passed: 13 contract tests, 48 synthetic gesture/runtime checks, 182 CLI integration checks, release compilation, and strict signature verification. Native rendered checks covered named/unnamed mappings, long names, dark/light appearance, minimum window height, selection changes, and toast layout. The build ran out of disk once; completed temporary test runners were removed and remaining compilation ran sequentially. Evidence is under `.build/gesture-name-*`.

Installed and relaunched 0.28.2 with the existing signing requirement and saved settings preserved. The previous app/settings backup is `.build/install-backups/2026-10-27T20-50-24Z`.

## Browser shortcut cleanup — 0.28.1 (62), 2026-10-27

Previous/next browser tab now use ordinary Key press actions (Control–Shift–Tab / Control–Tab). The duplicate System choices are removed. Legacy settings and CLI inputs migrate across mappings, stacks, and automations; exports use the canonical shortcut form.

Unit and contract tests, 181 CLI integration checks, 400/401 model checks, 58 stack checks, 53 transfer checks, and release compilation passed. The signed candidate at `.build/browser-shortcut-release/HandyToolbelt.app` was installed and relaunched from `dist/HandyToolbelt.app`. The running executable matches the candidate, the designated signing requirement is unchanged, and saved configuration is preserved. The previous app and settings are backed up under `.build/install-backups/2026-10-27T20-20-08Z`.

## Tester feedback — 0.28.0 (61), 2026-10-27

Three Sol implementation agents handled gestures, window behavior, and settings UI, followed by primary-agent integration and review. Review caught missing production stack wiring for double tip-taps, a dropped single when a different second tip began, repeated icon lookups, and an obsolete snapping commit path; these were corrected.

Regression coverage now includes moving then settling a resting finger, spacing/rim rejection, double tip-taps and cancellation, real deferred dispatch with anchors held, fresh-install defaults and saved choices, Coffee assertion release/reset, active new mappings and scope ordering, delayed AX size readbacks and rollback repair, cancellation during snapping writes, and multi-display/grid geometry.

All verification stages passed: unit/contract tests, 400/401 model checks, native window/lifecycle and gesture performance checks, 54 activation checks, 35 chooser-flow checks, 22 snapping-pipeline checks (including 100 cycles), 181 CLI checks, 58 stack checks, 52 native-click checks, 39 temporal checks, 53 settings-transfer checks, and login-item checks. Temporal checks were rerun separately after correcting a fixture that expired 50 ms before its configured deadline; transfer/login checks then completed separately. No production fix was required for that fixture error.

Native rendered review covered six disabled tool pages, mappings, app groups, and the Switcher layout preview. Release compilation and strict signature verification passed. The signed candidate is staged separately; the running app and user configuration were not replaced. Evidence is under `.build/feedback-*`, including UI snapshots in `.build/feedback-ui-review/`.

Still required on the affected Mac: physically drag Safari/Finder windows to top and side targets on both internal and external displays. Synthetic AX/event tests cannot confirm that Mac's native drag timing or window constraints.

## Earlier review

Review date: 2026-10-26. Historical candidate: early build 0.25.4 (50). The checks recorded below predate the HandyToolbelt rename and do not validate 0.27.0 (60). Paths and commands below use current names for navigation.

The feature set is frozen for this review. The work concentrates on correctness, recoverability, lifecycle boundaries, and useful regression coverage. This is a source review and local validation, not a substitute for testing other macOS versions and hardware.

## Findings addressed

| Finding | Resolution | Regression coverage |
| --- | --- | --- |
| Foreground application could change between successful focus observation and completion delivery. | The production activation coordinator now rechecks that the request is current and its target app is still frontmost before delivering success. | Focus returns to the origin or an unrelated app just before completion; cancellation at every activation stage; an overlapping newer request. |
| Settings recovery could hide a failed save and remove the unreadable file from its original path. | Recovery copies the original to a backup, atomically writes defaults, then publishes the recovered state. A failure leaves the original and recovery state intact. | Injected failed replacement, exact original/backup contents, unchanged model, blocked saving while recovery is pending, successful retry, and subsequent ordinary saving. |
| The old activation check covered a decision policy rather than the actual activation sequence. | `WindowCatalog` now uses a coordinator whose real orchestration is exercised by the harness. Only native effects, scheduling, and the clock are substituted. | 54 scenarios, including rejected AppKit requests recovered through AX foreground, successful AXRaise without focus, wrong selected window, restoration failure, local AppKit activation, delayed focus, bounded timeout, cancellation, and queue routing. |

Version 0.25.2 restored the AX foreground fallback and corrected the top snapping threshold. The user physically confirmed both fixes. The current coordinator preserves that sequence; the final candidate still needs the real-device smoke checks below.

## Additional integration and UI work in 0.25.4

- The real keyboard monitor, chooser, activation coordinator, stack key driver and host suspension routing now run together in deterministic checks. Cancellation clears the switch-in-progress gate, and stale activation callbacks cannot change a newer chooser or unlock a newer activation.
- The production snapping monitor is tested across capture, delayed resolution, coalescing, preview delivery and commit, including 100 repeated cycles on the same instance. Native effects are substituted; the production orchestration is not reimplemented by the tests.
- Switcher scope/inclusion controls and its separate try-out button were removed. Existing configuration and CLI fields remain compatible. The static layout illustration remains.
- Global Settings section and tool names have icons. Native disclosures accept clicks across their labels. Snapping explains its automatic disablement when native tiling is available, retains the saved preference, and dims its still-clickable tab. Availability uses the public separate-Spaces value and macOS version; it does not assert that the native drag-to-tile preference is enabled.
- SwiftUI publication warnings had two traced sources. Native Lists echoed unchanged selections during restyling; equality guards and idempotent styling removed those warnings (102 → 18 → 0 in the original harness). Installed-app control testing exposed a second path: the segmented Gesture workspace and device controls published during their own updates. Their choices now defer one main-loop turn, coalesce independently and reject stale navigation; direct model navigation stays synchronous. The harness now presses both native controls themselves (workspace reproduction: 52 warnings; device reproduction: 217 warnings; zero after the fixes), including cancellation and latest-choice checks. Permission/cache cleanup also avoids publishing unchanged values.

## Review scope

| Area | Reviewed boundaries and checks |
| --- | --- |
| Switcher and Snapping | Foreign AX work off the main thread; own-window handling through AppKit; request cancellation; focus verification; filtering; drag evidence and edge geometry; bounded diagnostics. |
| Gestures and stacks | Device/frame validation, raw-input recognition, native click/force separation, temporal gestures, focus and Gym isolation, held-key cleanup, disconnect/sleep/permission paths. |
| Configuration and CLI | Version migration, malformed input, validation, revision guards, atomic replacement, import review and backup, undo, local socket ownership/peer checks, request size and client limits. |
| Automations and Overlays | Serialized scripts, cancellation between steps, progress expiry, disabled/unavailable dependencies, stale callbacks, nonactivating panels. |
| App lifecycle | Login item status, restart, permission refresh, menu/Dock presence, startup defaults, session changes, and recovery from disabled services. |
| Resource use | Preview capture limited to explicit checks or the chooser; bounded memory cache/concurrency; no persisted screenshots; visible-only Power sampling and inactive visualizer clocks. Battery consumption was not measured. |
| Dependencies | Swift package has no third-party dependencies. Shipped sources use native Apple frameworks and local storage, without a network service or subprocess-based action execution. |

The code remains in Swift 5 language mode with Swift tools 6. A strict-concurrency migration and consolidation of the repeated app-source compilation in integration scripts are reasonable future maintenance work, not prerequisites for this patch.

## Automated validation

Run `swift Scripts/verify.swift` from the repository root. It runs SwiftPM unit tests and all app/model, native-window-presence, activation, gesture-performance, Gym-transition, CLI/service, stack-runtime, force-click, temporal-gesture, settings-transfer, and login-item checks sequentially.

`swift Scripts/verify.swift` passed for the integrated changes (exit 0); the final native-control-only correction was then rechecked with the full app-source Gym/control/lifecycle harness and release build, as detailed below. The development log is `.build/integration-stability-checks.log`.

- 66 XCTest cases and 102 Swift Testing cases passed.
- Model/feedback harness: 395 checks; the legacy-section variant: 396 checks.
- Production activation orchestration: 54 scenarios; complete switcher flow: 35 checks; snapping pipeline: 18 checks, including 100 repeated cycles. CLI/service integration: 152 checks.
- Stack runtime: 49; Force click model: 52; temporal gesture model: 32; settings transfer: 53.
- Native main-window presence, gesture performance, cached module/Gym transitions and lifecycle, and login-item fake-driver/startup-policy harnesses passed.

These counts describe different suites and variants; they are not a count of independent end-to-end user flows.

The activation harness does **not** post input or call the real macOS activation APIs. It can catch a missing foreground step or incorrect success/cancellation logic, but it cannot prove OS permission grants, cross-Space behavior, or physical Option-release delivery. The complete keyboard-monitor → chooser → catalogue flow is covered with native boundaries substituted; physical input and real OS focus remain device checks. See [Window activation validation](Window-activation-validation.md).

## Installed candidate and stability check

The optimized 0.25.4 (50) build passed and was installed with a verified signature and the same designated signing requirement. Both the original 0.25.3 bundle and intermediate test build have local rollback backups. Post-install CLI verification confirmed one app process, unchanged configuration, Accessibility granted, Start at Login retained, and no running automation.

Visual inspection confirmed the simplified Switcher form and retained static illustration, Global Settings icons, active Snapping status, and disclosure text opening and closing the section when clicked away from the arrow. The native-tiling eligibility branch is covered by model tests; this Mac's Spaces preference was not changed. Global Settings was restored after testing.

The full verification suite passed before the final two-control warning fix. After that narrow change, the complete app-source native Gym/control/lifecycle harness and optimized build passed again. The harness now drives the actual workspace and device segmented controls, with explicit deferred-publication, latest-choice, cancellation, visibility, calibration and direct-routing guards.

The first installed stability pass completed eight module/subtab navigation cycles (88 actions) without a hang or crash. The final build then completed six additional asserted cycles after warming all pages: 78 selections spanning every module, all Gesture subtabs, and Trackpad/Magic Mouse. Every selection reached the expected page. The user configuration remained unchanged.

Final-build RSS was approximately 187 MiB after warming, 174 MiB after three cycles, and 174 MiB after six. It remained at about 174 MiB after a 42-second settled interval; cumulative CPU time increased by 0.73 seconds (about 1.8% of one core) while Global Settings was visible. This short run showed bounded resident memory, not proof against every leak. Resource samples and the settled idle interval are recorded in `.build/integration-stability-samples.json`; they are not a battery/energy measurement.

Installed runtime inspection found zero SwiftUI publication warnings after the final control fixes. AppKit's selective-sharing indicator still logs geometry faults during UI-tool inspection, as described below. No app crash or navigation hang was observed. Physical modifier release, actual focus/snapping, fresh permissions and the multi-Mac matrix remain manual gates.

Local evidence: `.build/integration-stability-checks.log`, `.build/integration-stability-build.log`, `.build/integration-stability-verification.json`, `.build/integration-stability-final-runtime-errors.json`, `.build/integration-stability-samples.json`, and `.build/ui-device-picker-fixed-check.log`.

## Known unresolved observations

- AppKit negative-geometry faults during app-control inspection were traced to macOS's window-sharing indicator: `_positionSharingIndicator` / `NSWindowSharingSessionRecipientIndicator` during selective sharing. A stationary AX inspection reproduced them without app navigation; the backtrace contains no app layout code. No speculative hosting/geometry workaround was added. SwiftUI publication warnings have a separate, fixed cause described above. Installed-app navigation after the final fix recorded zero SwiftUI publication warnings.
- Multitouch input uses an undocumented Apple framework. The narrow boundary validates incoming data, but compatibility still needs hardware and OS testing. Pressure visualization is not used to invent Force Touch capability on unsupported hardware.
- This local build uses a development signing identity without hardened runtime. The packaging script does not notarize or staple. Keep this candidate for controlled local testing; prepare and validate a Developer ID distribution package before broad external distribution. Do not silently replace the development identity on this Mac, which can invalidate its stored permissions.

## Wider-testing checklist

Record the build, macOS version, Mac/trackpad model, display arrangement, target apps, and pass/fail for each test. A UI automation tool that bypasses global event taps does not count as physical-input verification.

1. **Switcher:** Option–Tab/release, Shift alone and Shift–Tab, two windows of the same app, minimized and hidden windows, another Space, HandyToolbelt itself, Escape, target closure, and rapid repeat requests. Confirm the chosen window receives keyboard input.
2. **Snapping:** first upward drag to the menu bar, left/right edges, corners, secondary displays with different origins/scales, moving away before release, and click/resize/content drags that must not snap. Test both shared and separate Spaces and the native-tiling conflict explanation.
3. **Gestures:** tip-taps, long touch, double taps, click/force arbitration, corner stacks and held-key release. Check built-in and external trackpads, non-Force hardware, and Magic Mouse where supported. Gym suppresses production actions only while its page and app are focused.
4. **Permissions and lifecycle:** fresh install, permission denied/revoked/restored, preview setup prompts, screen lock/display sleep, wake, device reconnect, quit/relaunch, and login launch. No stale input, stuck modifiers, or delayed focus theft.
5. **Settings and automation:** import/export via local and iCloud Drive folders, stale import rejection, malformed/newer-version files, recovery failure/retry, revision-guarded CLI edits/undo, a script failure, and cancellation of a multistep workflow.
6. **UI and resources:** every module and Gesture subtab, rapid navigation and scrolling with live contacts, all four chooser layouts/preview sizes, menu open/close, reduced motion, and a longer idle/active session checked in Activity Monitor for CPU, memory, and energy use.

Fresh-install/TCC flows and other hardware are intentionally pending. Do not reset the developer's working permissions or configuration to simulate them.
