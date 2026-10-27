# HandyToolbelt CLI

The signed app includes `Contents/MacOS/handytoolbelt`. Run that executable by its full path, or create your own shell alias. Keep the alias pointing into the app bundle so app updates also update the CLI; a separately copied executable can become outdated. HandyToolbelt does not edit PATH or shell configuration. Open the app and enable Allow CLI control before calling the CLI; the CLI never launches it automatically. The running app's `schema` is authoritative.

```sh
/path/to/HandyToolbelt.app/Contents/MacOS/handytoolbelt --help
/path/to/HandyToolbelt.app/Contents/MacOS/handytoolbelt schema
/path/to/HandyToolbelt.app/Contents/MacOS/handytoolbelt status
```

Commands return one JSON response on stdout, including failures. Exit codes are 0 for success, 1 for a rejected command, 2 for command-line/input errors, and 3 for connection or transport failures. Local diagnostics also go to stderr. `--help` prints usage text instead of a JSON response.

The complete [generated command reference](CLI-reference.md) lists every command, its input and successful result schema, and example parameters. `--help` works offline and includes all protocol commands. Friendly aliases cover common workflows; `call` forwards any command name and JSON object unchanged, including commands added by a newer app.

CLI control is off by default, including on existing installations. Enable **Allow CLI control** in HandyToolbelt → Settings → Automations & CLI on each Mac. This persistent local choice is excluded from settings exports, imports, and CLI configuration; it is managed in the app and unavailable through configuration or CLI commands.

Once enabled, scripts and agents running as your macOS user can change settings and run actions using HandyToolbelt’s permissions without approval for individual commands. The private socket’s same-user checks do not distinguish trusted scripts from other processes running as that user. This opt-in is intended for a trusted same-user environment, not as a tamper-resistant boundary against malware able to edit your local preferences or settings.

Turning it off closes the listener and drops queued requests; actions already started can finish. In-app and gesture automations remain available while CLI control is off. The section shows actual CLI availability and offers Retry if listening fails.

## Configuration

Configuration examples in the reference illustrate shape only. `config apply` replaces the complete configuration; it does not merge a patch. Always edit a fresh `config get` result and preserve fields you are not changing.

Trackpad configuration is supported through the complete configuration: `bindings` contains gesture, device, action, and optional application-group scope; `applicationGroups` defines those scopes; `trackpadTuning` includes hand angle and detection thresholds. Edit these fields in the exported configuration while retaining unrelated fields, validate, then apply with its revision. Ordinary gestures without a held corner require 2–5 fingers. Corner gestures and stack children permit one finger. Left/right tip-taps and tip-swipes permit 2–4 fingers (1–3 resting fingers plus one active finger); middle tip-taps require three. The held corner is an additional finger. Set `kind` to `tipTapMiddle`, `tipSwipeLeft`, `tipSwipeRight`, `tipSwipeUp`, or `tipSwipeDown` for the new variants; existing two-finger tip-taps keep their meaning. Gesture Gym and live contact inspection are available in the app UI. Set a binding’s `showsToast` to `false` to exclude it from global recognition toasts; missing values default to `true`. This never forces feedback on: both `visualFeedbackEnabled` and `displayModuleEnabled` must be enabled.

```sh
handytoolbelt config get
handytoolbelt config validate --file configuration.json
handytoolbelt config apply --file configuration.json --revision REVISION_FROM_CONFIG_GET
handytoolbelt config undo --revision CURRENT_REVISION
cat configuration.json | handytoolbelt config validate --stdin
```

Configuration writes require the revision reported by the app. Changing `trackpadModuleEnabled` or `windowSwitcher.isEnabled` from false to true also requires Accessibility access. `config validate` checks configuration structure; apply checks this runtime requirement before saving. Missing access does not block disabling tools or editing unrelated preferences. Validation and application wrap the supplied JSON object in the `configuration` parameter; the server validates its contents. Use `schema` for the app's canonical command and configuration contract.

`config get` returns an envelope: edit the object at `result.configuration`, then save that object alone as `configuration.json`. Keep `result.revision` for apply. Validation returns `errors` and `warnings`; an empty errors array means the configuration can be applied. Unknown fields, invalid references, unsupported values, and conflicting enabled mappings are rejected. Incomplete disabled mappings can produce warnings. Apply writes atomically before replacing live settings. Undo is available for the last apply during this app session, and refuses to overwrite later UI or CLI edits.

## Overlays

```sh
handytoolbelt display text 'Build complete' --duration 0.5
handytoolbelt display toast 'Saved' --duration 1
handytoolbelt display progress begin 'Deploy' --steps 'Prepare,Build,Verify'
handytoolbelt display progress update PROGRESS_ID --step 1 --state completed
handytoolbelt display progress update PROGRESS_ID --step 2 --state running --message 'Compiling'
handytoolbelt display progress finish PROGRESS_ID
handytoolbelt display progress finish PROGRESS_ID --failed --message 'Verification failed'
handytoolbelt display dismiss PROGRESS_ID
handytoolbelt display dismiss
```

Durations accept 0.2–5 seconds. Progress steps are numbered from 1; states are `pending`, `running`, `completed`, and `failed`. The begin response supplies the progress ID. Omitting the dismiss ID dismisses the current display.

The UI calls this tool **Overlays**; `display` command names remain unchanged. Overlays has its own enable switch. Requests return `displayed:false` when it is disabled or unavailable; automations can still run with Overlays disabled. Progress takes precedence over brief toasts. Up to four sessions are retained, with the newest active session preferred. Update external progress within 30 seconds to keep its session alive. In-process automation progress remains until the run ends or feedback is dismissed. Completion stays for one second and failure for three; expired or dismissed IDs cannot be updated. Enabling Overlays does not replay old feedback.

## Automations

```sh
handytoolbelt automations list
handytoolbelt automations run 'Automation name or ID'
handytoolbelt automations status RUN_ID
handytoolbelt automations cancel RUN_ID
```

The app owns automation execution and returns run IDs and status. The CLI sends commands through local IPC and does not execute shell commands or external programs.

Definitions live in `configuration.automations` and in Settings → Automations & CLI → Edit Automations. Add Example supplies editable IDs and valid action fields. Each automation has `id`, `name`, and 1–32 `steps`. A step has its own `id`, `name`, and exactly one `action` or `delay` (0–30 seconds). Actions use the existing shortcut, system, AppleScript, and Show Text types. Nested automations are rejected. A gesture binding can select an automation by ID.

One run is active at a time; status retains the latest 20 runs. Cancellation stops waits and future steps. A native AppleScript already executing cannot be interrupted: its run reports `cancelling` until the action returns. Sleep and session deactivation cancel future steps. The Gestures enable switch does not gate CLI runs; individual actions still require their normal system permissions and module availability.

An AI agent with command execution can use this same interface: read `schema` and `config get`, edit a copy, inspect validation errors, apply with the original revision, and inspect the returned result. No separate MCP server or AI service runs inside HandyToolbelt.

## Full JSON calls

```sh
handytoolbelt call status
handytoolbelt call display.text --json '{"text":"Hello","duration":0.5}'
handytoolbelt call COMMAND --file parameters.json
cat parameters.json | handytoolbelt call COMMAND --stdin
```

The input must be a JSON object. Choose at most one of `--json`, `--file`, or `--stdin`. Full calls support richer parameters described by `schema`. Human shortcuts use the same server commands (`display.text`, `config.apply`, and so on).

## Local connection

The app listens only on the Unix-domain socket `/tmp/handytoolbelt-<uid>/control.sock`. Its directory is private to the current user (0700), its socket is 0600, and both sides verify ownership and same-user peer credentials. There is no TCP or HTTP listener. Each connection carries one bounded newline-delimited JSON request and response (up to 1 MiB each), with finite timeouts and at most eight concurrent clients.

For isolated tests, use `handytoolbelt --socket /private/test-directory/control.sock status`. The override must point into a private directory owned by your user. A missing app or socket produces an actionable error rather than starting the app. The server only removes a stale socket after a definite refused connection and matching filesystem identity; it rejects unsafe files and symlinks.

## Coffee

`call coffee.status` reports module enablement, pause/running state, requested and effective modes, and any native power assertion error.

```sh
handytoolbelt call coffee.set --json '{"preventIdleSleep":true,"keepDisplayAwake":false}'
```

Provide either or both Boolean properties; omitted modes retain their selection. Activation requires the host running, Coffee enabled. Disabling remains available. Native assertion failures return `power_assertion_failed`; inspect status and Retry Coffee in the app. Selections last only for the running process. `coffeeModuleEnabled` is the persisted configuration switch and defaults to true for older settings.

## Development verification

Run `swift Scripts/verify.swift` for sequential unit tests, model checks, and isolated real CLI integration checks. The integration harness uses temporary configuration and a private socket with fake native actions and power assertions. Normal packaging runs this verification before its release build.

The command enum and its exhaustive specifications in `HandyToolbeltControl/Contract.swift` own input/result shapes, descriptions, and examples. The app dispatches that enum exhaustively. Core owns gesture/action enums and tuning limits shared by the UI and contract. The validator implements a deliberately small schema subset; contract tests reject unsupported keywords and unresolved references. Configuration reference checks and conflicts remain server semantic validation.

After intentional contract changes, run `swift Scripts/verify.swift --generate-docs`, review `Docs/CLI-reference.md`, then run normal verification. Tests check generated reference drift, metadata, offline help, examples, and actual handler results for every command.

`forceClick` is a gesture kind for Force Touch trackpads, with 1–5 fingers or 1–4 free fingers with a corner or as a stack child. Magic Mouse Force click bindings fail validation when enabled (disabled drafts warn). Recognition uses native macOS pressure stage 2 only. The native app click may also occur; a paired `click` mapping waits for release and is discarded when Force click fires. Raw pressure remains visualization-only.

Temporal gesture kinds are `longTouch` and `doubleTap`. They share Tap's finger limits and support corner modifiers and stack children. Tuning adds `longTouchDuration` (0.30–1.50 seconds, default 0.55) and `doubleTapInterval` (0.15–0.60 seconds, default 0.28). Legacy tuning objects may omit these two fields; decoding supplies their defaults. Other tuning keys remain required by the CLI. Double tap delays an overlapping applicable single Tap until its interval expires, including when no input frames arrive. The second touch must start within that interval; a valid tap may finish afterward within `tapDuration`. The two chord centroids must be within `2 × tapTravel`.

Double tip-tap variants are `doubleTipTapLeft`, `doubleTipTapRight`, and `doubleTipTapMiddle`, with the same resting-finger limits as their single variants. They use `doubleTapInterval`, keep the same anchors between taps, and work in gesture stacks. Anchored tuning adds `tipMaxSeparation` (0.15–0.80 surface-width units, default 0.45) and `tipEdgeDeadzone` (0–0.15 of each trackpad axis, default 0.04). Older tuning objects may omit these fields. The rim exclusion applies to resting trackpad contacts, excluding a separate corner modifier.

`windowSwitcher.gridScale` adjusts grid popup size from 0.75 to 1.5 (default 1), independently of `previewScale`; the result stays within the display. Fresh configurations start with all tools off. Disabling Coffee clears its runtime selections as well as releasing assertions.

Gesture stacks appear as collapsible folders in Saved mappings. Select a folder to edit its held corner, app scope, required keys, start actions and release actions. Add Gesture creates a child beneath it; selecting that child opens its individual gesture and ordered action sequence. Children run only while their folder is held. A child’s optional `name` uses the gesture title when blank or omitted and is limited to 120 characters.
