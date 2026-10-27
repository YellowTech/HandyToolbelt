# HandyToolbelt security and threat review

Reviewed 2026-10-26 at source commit `7acea68`, with a clean starting working tree. The inspected packaged app was version 0.26.7 (59). The original review and probes did not change runtime behavior. Historical source locations below refer to that commit.

## Follow-up: CLI opt-in, 2026-10-27

The user chose a single local opt-in while retaining prompt-free agent automation. `CLIControlModel` now keeps the **Allow CLI control** preference outside the transferable configuration. Missing consent defaults to off, including when upgrading an existing installation. Enabling starts the private listener while the host runs; disabling stops the listener and invalidates queued requests. Already-dispatched actions can finish. Stopping/restarting the app preserves consent, and listener failures remain visible with a Retry action.

Imports and protocol commands cannot change this preference. Once enabled, the existing same-UID checks and full command workflow remain intact: agents can inspect, validate, apply, and run without per-command or per-script approvals. In-app and gesture automation remain independent of the CLI switch.

This addresses default exposure and makes the trust decision explicit. It is **not** caller isolation or tamper-resistant authorization against malware already able to modify this user's preferences/settings. Blanket same-user trust after opt-in is an accepted product tradeoff; stronger executable-content approval is deferred. The other review findings below are unchanged. The installed bundle and production preferences were not modified as part of this implementation.

Follow-up validation: `swift Scripts/verify.swift` passed on the final source, including 66 XCTest tests, 102 Swift Testing tests, all host/gesture/lifecycle checks, 181/181 CLI integration checks, 53 settings-transfer checks, and login-item checks. The CLI checks cover default-off startup, persistence, immediate enable/disable, queued-request revocation across re-enable, configuration isolation, startup failure/retry, and continued in-app/already-started automation. Native SwiftUI renders of off, ready, and error states were reviewed in light and dark appearance. Test endpoints and preferences were isolated; the suite log and UI renders remain under ignored `.build/`.

## Assessment

The app has a small direct remote attack surface, but substantial authority once Accessibility and other permissions are granted. Local operation removes a server, accounts, remote APIs, and third-party runtime dependencies from the threat model. It does not make executable settings or local command callers trustworthy.

At the reviewed commit, the most important boundary was the always-enabled local command interface: every process able to connect as the same user could replace configuration and run automations. The follow-up above makes that interface opt-in. Imported settings are another way to introduce executable behavior, with a meaningful user review step already present. Keeping the permissions needed for gestures and window management is reasonable; controlling which instructions reach those permissions is the main improvement.

## Threat model

| Actor/input | Required access | Boundary and consequence at the reviewed commit |
| --- | --- | --- |
| Remote website or network peer | No local foothold or user import | No direct TCP/HTTP listener, web view, remote configuration fetch, or custom inbound URL handler was found in the reviewed source. |
| Malicious shared settings file | User selects the file and confirms replacement, then triggers its behavior | Valid JSON can contain AppleScript and enabled mappings. Parsing does not execute it; subsequent use can. |
| Untrusted local process | Same user, ability to access the Unix socket, app running | Can read/apply configuration and start automations without app-level approval. macOS permission and session checks still apply to the app. A sandboxed caller may be blocked by its own sandbox. |
| Local settings tampering | Write access to the user's settings file; subsequent app load | Script/action changes are loaded without a separate trust decision. This remains relevant even if the CLI is restricted. |
| Another ordinary local user | Different UID | Socket directory/file permissions and peer UID checks reject this case under the normal endpoint layout. |
| Root, compromised OS, or attacker already controlling the app binary | Already beyond the intended app boundary | Not a boundary this review claims the application can defend. |

## Prioritized findings and design risks

### 1. High priority: local control can turn another process's instructions into app-authorized actions

**Evidence:** `Sources/SuperToolsControl/Transport.swift:131` authenticates the peer's UID only. `Sources/SuperTrackpad/Host/ProductivityModel.swift:96` defaults the server to enabled and starts it at line 136. `Sources/SuperTrackpad/ControlCommandService.swift:117` applies supplied configuration, and line 161 starts a named automation. Neither operation has a separate user-approval or executable-content trust check. The revision returned by `config.get` prevents stale writes; it is not authorization.

An isolated generic Python process successfully performed `config.get` → `config.apply` → `automations.run` against the production server/service implementations. The added AppleScript action reached a recording-only executor and persisted to temporary settings. No bundled CLI, token, or app approval was required. Production dispatch leads to native key posting or `NSAppleScript` in `Sources/SuperTrackpad/ActionExecutor.swift:38` and line 49.

**Impact and prerequisites:** A malicious or compromised unsandboxed local program can ask the already-authorized app to perform input/actions on its behalf. This requires a local foothold and the app's relevant grants; it is not unauthenticated internet execution or proof of an OS TCC bypass. The protocol intentionally supports scripts and AI agents, so the question is whether all same-user callers should inherit that trust automatically.

**Recommended boundary:** Make powerful CLI control an explicit opt-in. For a stronger boundary, require in-app approval for newly supplied or changed executable behavior and restrict unattended runs to approved definitions. Include shortcuts and referenced automations in that policy, not just AppleScript text. Keep safe status/overlay capabilities separately configurable. Authenticating only the bundled CLI is insufficient if any process can launch it; a token in a same-user-readable file also does not solve this threat.

Apply the same trust policy to persisted configuration. `Sources/SuperTrackpad/ConfigurationStore.swift:13` decodes local settings directly, and `Sources/SuperTrackpad/AppModel.swift:248` adopts them at startup. A portable `trusted: true` field or editable approval list beside the JSON would let a file writer approve its own changes. Any protected trust record must be separate from imported settings and resistant to the particular same-user caller threat being addressed.

### 2. Medium priority: imports install executable behavior, despite safe parsing

**Evidence:** `Sources/SuperTrackpad/SettingsTransferView.swift:71` counts AppleScript definitions and correctly explains that later use can execute actions. Line 78 offers a collapsed preview of the complete JSON. `Sources/SuperTrackpad/SettingsTransferModel.swift:127` applies the reviewed configuration while retaining its enabled mappings and scripts. The `authorize` callback checks permission requirements for enabling modules, not trust in script contents.

This is a social-engineering/design risk, not an identified JSON parser exploit or automatic execution on file selection. A person importing a useful gesture preset may approve it without recognizing a hostile action nested in a stack or automation. Existing macOS grants do not constitute approval of each new script.

`NSAppleScript` is a full scripting engine. Apple documents that its Standard Additions `do shell script` command can run command-line tools. Thus, the absence of Swift `Process` calls does not prohibit scripts from executing shell commands or causing network activity. File changes, other application actions, and command execution remain subject to applicable OS permissions. [Apple: Calling Command-Line Tools](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/CallCommandLineUtilities.html).

**Recommendation:** Preserve the review/backup flow, but make executable content conspicuous. Prefer importing new executable behavior as inactive/unapproved until the user explicitly enables it. Approval must cover nested/referenced actions and be invalidated by later CLI or disk changes. Treat scripts as trusted code; trying to blacklist a few AppleScript commands is not a reliable sandbox.

### 3. Medium priority: stack cleanup also dispatches arbitrary release actions after suspension

**Evidence:** `Sources/SuperTrackpad/AppModel.swift:519` marks the input session unavailable for lock/sleep and calls `suspendInputMonitoring`. That method calls `stackRuntime.end()` at line 539. `Sources/SuperTrackpad/GestureStackRuntime.swift:253` always starts the configured release sequence, and line 259 advances subsequent actions without a session or cancellation-generation check. The AppModel executor closure at line 51 forwards actions without checking session availability. `stop()` also shares this ending path.

Automatic key release is necessary. However, the release sequence may contain AppleScript, key presses, or application launches. It can start new actions as the app suspends, or continue from an asynchronous callback after the module stops. The existing product specification explicitly describes release actions on every ending; this is a security policy concern in that intended behavior, not an accidental regression claim. Action-specific macOS/module checks may still reject particular effects.

An isolated production-AppModel probe confirmed dispatch of an AppleScript-kind release action after both lock and sleep marked the session unavailable. A delayed first release completion also dispatched the next action after the model was locked and stopped. The execution boundary was replaced with a recording-only callback, and the fake keyboard recorded zero emission attempts.

**Recommendation:** Distinguish normal finger release from cancellation for lock, sleep, shutdown, or unavailable permissions. Always release owned keys; suppress additional user actions on cancellation and invalidate outstanding release continuations. This does not require interrupting AppleScript that was already executing.

### 4. Medium priority before distribution: the packaged app has no Hardened Runtime

**Evidence:** `Scripts/build.swift:93` and line 95 sign without `--options runtime`. Read-only inspection of `dist/HandyToolbelt.app` reported `flags=0x0(none)`, a development signature, and no entitlements. The build script has no notarization/stapling step. The older release review already records this limitation.

Hardened Runtime reduces code injection, library hijacking, and process-memory tampering opportunities. This is especially relevant to an application trusted to control input or capture windows. The missing protection was verified; an injection exploit was not attempted. [Apple: Hardened Runtime](https://developer.apple.com/documentation/Security/hardened-runtime).

**Recommendation:** Add a deliberate distribution configuration using Hardened Runtime, the minimum necessary entitlements, Developer ID signing, notarization, and stapling. Test native scripts, event taps, the private multitouch framework, and login startup before shipping it. Preserve the existing development identity while preparing that configuration to avoid unnecessarily disrupting this Mac's permissions.

Full App Sandbox is a separate architectural decision. Apple's documented restrictions include assistive Accessibility APIs and sending Apple Events to arbitrary apps, so enabling it blindly would conflict with core behavior. [Apple: Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox).

## Protections already present

- Imports read at most 1 MiB plus one detection byte, off the main thread, with file-provider coordination. The decoder checks shape, versions, references, bounds, and conflicting enabled mappings.
- Import review uses the decoded snapshot. It rechecks configuration revisions and busy-state gates before apply, creates a backup first, and persists atomically before publishing settings.
- The local socket uses a 0700 directory, 0600 socket, UID checks in both directions, endpoint type/symlink checks, bounded messages, eight concurrent clients, deadlines, and conservative stale-socket cleanup.
- Window previews are one-shot captures of selected windows, with audio disabled, bounded image size/concurrency/cache, and in-memory image clearing on chooser/session end. No screenshot disk persistence or screenshot export command was found. The default switcher does not require previews.
- The reviewed keyboard handling uses transient shortcut/modifier state; no general keystroke log, clipboard harvesting, telemetry, third-party runtime dependency, or built-in network client was found.
- Native multitouch loading uses a fixed system framework path, copies callback data, and checks contact count, coordinates, and freshness. Its undocumented ABI remains a compatibility/memory-safety testing concern, rather than an identified remote entry point.

## Permissions and remaining hardening

Accessibility is justified by input synthesis and window control. Input observation supports global shortcuts/click recognition. Screen Recording is optional and used for previews; Automation access is relevant only to scripts that address other applications. Removing these grants would disable associated functionality. The security goal is to constrain accepted instructions and retained data while keeping the necessary capabilities.

Settings, backups, and exports contain the full plaintext scripts and configured text. They should not be treated as secret storage, and exporting to a synced/shared folder transfers that content. Under the probe's inherited umask 0022, newly created store directories/files were 0755/0644. The probe used a private parent, so this does not demonstrate production cross-user access. Explicit 0700 app-owned directories and 0600 settings/backups would remove reliance on ancestor permissions and umask; they would not stop another unsandboxed process under the same UID.

Local startup loading also lacks the import path's size limit and semantic validation. Reusing bounded validation is sensible hardening against corrupted/tampered files. Atomic writes protect against partial saves, not malicious content. AppleScript execution is serialized but cannot be forcibly cancelled by the current runner; a non-returning script can monopolize that executor. The UI/CLI already disclose the cancellation limitation.

## Validation and limits

- `swift test --filter SuperToolsControlTests`: 20 tests passed.
- `swift Scripts/check-settings-transfer.swift`: 53 checks passed.
- `swift Scripts/check-control-integration.swift`: 152/152 checks passed.
- Isolated generic-client/configuration probe: 3/3 assertions passed, demonstrating the current trust boundary.
- Isolated AppModel session-release probe: 4/4 assertions passed, characterizing release dispatch during lock/sleep and after stop without native effects.
- Read-only package inspection confirmed version 0.26.7 (59) and absent Hardened Runtime.

Probe sources, command records, logs, and preserved source excerpts are under the ignored `.build/security-review/` directory. Native actions were replaced with recording-only callbacks; sockets/settings were temporary. The production endpoint was not contacted, and no real script, key injection, permission reset, bundle replacement, or sensitive-data capture was performed. Passing functional checks does not establish that the security boundaries are sufficient.

This is a targeted source/threat review with isolated behavioral validation, not exhaustive fuzzing or a penetration test across macOS releases. OS-level TCC attribution, fresh-permission flows, hardened-runtime compatibility, hostile hardware/driver input, and actual injection resistance remain untested.
