# Development

The app is pure Swift using Apple system frameworks and local storage. Runtime actions do not launch subprocesses. The package uses Swift 5 language mode with a Swift 6 toolchain and macOS 26 SDK or newer; the runtime minimum is macOS 14.

`swift Scripts/build.swift` runs verification, builds release executables for the current architecture, packages `dist/HandyToolbelt.app`, and signs and verifies the CLI and app. Quit any repository copy before rebuilding. This is a development build, not a notarized distribution release.

Signing selects the sole available Apple Development/Mac Developer identity and pins it in the ignored `.local-signing-identity` file. Select another identity explicitly with `SUPERTRACKPAD_SIGN_IDENTITY='YOUR_SIGNING_IDENTITY' swift Scripts/build.swift`. Use `SUPERTRACKPAD_SIGN_IDENTITY='-'` only for disposable ad-hoc builds; rebuilding them can invalidate macOS permissions. Test permissions with the packaged app, since `swift run` has a different executable identity.

Gesture input uses Apple's private `MultitouchSupport` framework. Its undocumented interface may change across macOS versions; hardware and OS compatibility require real-device testing. If native click detection is unavailable, check Input Monitoring and relaunch.

Compatibility identities remain `local.SuperTrackpad`, the `SuperTrackpad` executable and settings location, and the SwiftPM modules/products. The public bundled CLI is `handytoolbelt`; `supertools` remains a relative symlink alias. Its private socket remains `/tmp/supertools-<uid>/control.sock`.

See [release review](Release-review.md) and [window activation validation](Window-activation-validation.md) for recorded results and manual checks.


### Icon assets

`Resources/Toolbelt.svg` is the editable 24 × 24 glyph. Export it as a transparent,
24-point square vector PDF with black fills to
`Sources/SuperTrackpad/Resources/Toolbelt.pdf` after changing the SVG. Keep its
orientation upright (tools above the pouch). The checked-in PDF is used directly
by the menu bar and by `xcrun swift Scripts/render-icon.swift`, which writes
`.build/AppIcon.icns` without building, signing, installing, or stopping the app.
Add `--preview` to also update `Design/ToolbeltRefinements/approved-preview.png`.

SwiftPM copies the PDF into its resource bundle for `swift run`. Packaged apps
instead carry it at `Contents/Resources/Toolbelt.pdf`; `Scripts/build.swift` copies
it there and generates `Contents/Resources/AppIcon.icns`. When staging an app
manually from `.build/release`, copy that PDF and the generated ICNS into
`Contents/Resources` before signing. No SwiftPM resource bundle is needed in the
staged app because it loads the main-bundle PDF first.

For a staged update, quit the app and replace its `Contents` while keeping the
outer `.app` directory in place. Move the old contents into a separate rollback
bundle; moving the installed bundle itself can redirect existing file bookmarks.
