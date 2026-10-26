# HandyToolbelt

HandyToolbelt is a native macOS productivity app with six independently enabled tools in one menu-bar app:

- **Gestures:** map trackpad and Magic Mouse gestures to shortcuts, actions, AppleScript, and automations; practise in the Gym.
- **Switcher:** choose windows in a list or grid, with optional previews.
- **Snapping:** drag windows to screen edges for halves, quarters, or fill layouts.
- **Overlays:** display text, gesture feedback, toasts, and automation progress.
- **Power:** inspect battery, adapter, and estimated power readings.
- **Coffee:** prevent idle sleep or keep the display awake.

Written entirely in Swift with Apple system frameworks, HandyToolbelt keeps settings locally and has no third-party runtime dependencies or network services. Native input feeds gesture state machines; a shared host manages tool lifecycles. The bundled CLI shares the app's configuration and action contracts through a local socket.

## Build and run

Requires **macOS 14+** at runtime and **Xcode 26 SDK or newer with Swift 6** to build. Quit the repository's running app before packaging:

```sh
swift Scripts/build.swift
open dist/HandyToolbelt.app
```

Run checks without packaging:

```sh
swift Scripts/verify.swift
```

Grant Accessibility for actions and window management; optional previews need Screen Recording, and scripts may request Automation access.

See the [CLI guide](Docs/CLI.md), [command reference](Docs/CLI-reference.md), and [development notes](Docs/Development.md).

[MIT](LICENSE) · Copyright (c) 2026 HandyToolbelt contributors.
