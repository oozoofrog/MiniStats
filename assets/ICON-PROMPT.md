# RetroStats app icon

An ivory enclosure with a recessed olive LCD and four square-cell statistics
meters. The colors follow the Ivory finish in `RetroStats/PixelUI/RetroTheme.swift`.
A small status light and front-panel slot recall classic Macintosh hardware.
The large screen and separated meters carry the silhouette at small sizes;
there is no text or glow. Pixels outside the enclosure are transparent.

## Regeneration

Run `xcrun swift scripts/generate-app-icon.swift` from the repository root to
write the 1024×1024 sRGB RGBA master, `assets/AppIcon.png`. The Core Graphics
generator is the editable artwork source and needs no external dependencies.

`build.sh` uses `sips` to regenerate all ten native macOS PNG sizes in
`RetroStats/Assets.xcassets/AppIcon.appiconset`. Xcode's asset compiler packages
the app icon into the built bundle. `make verify` checks the release build,
self-tests, bundle, signature, and architecture; it does not install the app.

## Verification — 2026-10-25

Regeneration in a temporary directory produced a byte-identical PNG.
[Reproduction log](../build/logs/icon-commit-reproduction-20261025.log).
The staged icon and preceding storage/Tailscale commits passed `make verify`
in an isolated export. [Build log](../build/logs/icon-commit-verify-20261025.log).
This verification did not reinstall the app or publish a release artifact.
