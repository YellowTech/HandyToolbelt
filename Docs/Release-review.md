# HandyToolbelt release review

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
