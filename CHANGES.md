# MiniStats reviewed fixes

These files are based on the current project structure reviewed on 2026-09-14.

## Changes

- `Popover.swift`
  - Fixes transient tracking so it is installed while the popover is `.showing` or `.shown` rather than returning immediately.
- `Dashboard.swift`
  - Enables `NSGlassEffectView.effectIsInteractive` on macOS 27+.
  - Preserves a single `NSHostingView` across Reduce Transparency changes so SwiftUI local state is not reset just because the AppKit surface changes.
- `main.swift`
  - Removes the redundant second `makeKey()` call after `TransparentPopover.show()` already makes the panel key.
- `Makefile`
  - Makes `make install` build and deploy the current checkout instead of cloning GitHub and potentially ignoring local changes.
- `scripts/deploy-app.sh` (new)
  - Centralizes stopping the running app and installing a built bundle.
  - Copies to a temporary sibling first, keeps the previous install as a rollback backup during replacement, and only uses `sudo` when the destination is not writable.
- `scripts/run.sh`
  - Builds, installs to `${DIR:-$HOME/Applications}`, then launches the installed copy.
- `scripts/install.sh`
  - Reuses the same safe deployment helper after clone + `make verify`.

## Expected commands

```sh
make run
make run DIR=/Applications
make install
make install DIR=/Applications
```
