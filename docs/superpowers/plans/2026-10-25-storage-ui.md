# Storage UI implementation plan

> **For agentic workers:** Use superpowers:executing-plans in this session. Follow the approved UI scope below and preserve repository verification.

**Goal:** Apply the reviewed RetroStats UI, with all mounted-volume capacities in the app and the existing main-disk-only macOS status icon.

**Architecture:** A read-only, background volume catalog feeds Storage, Overview and the menu summary. Selection and optional read-only folder inspection belong to Storage. Existing cleanup, recovery, notification, Tailscale and permission controllers retain their authority.

**Tech Stack:** Swift, AppKit, SwiftUI, Foundation, Darwin; macOS 26+; no dependencies.

**Spec:** Approved conversation design; scope and decisions below are the persistent specification.

## Approved scope

- Keep `MenuBarReadout` and `StatusReadout` unchanged: main disk only, current used-space fill and CPU/memory readout.
- Storage: mounted internal/external/network volumes, free/used/total, selection, explicit unavailable state, APFS shared-capacity annotation, separately labelled purgeable estimate, measured time, refresh and Finder access.
- Space exploration: explicit read-only folder scan, drill-down, cancellation, actual measured file sizes only. Unknown/inaccessible/unscanned space must not become invented categories or cleanup candidates.
- Overview and popover: all-volume summaries and direct Storage access. Preserve existing metrics, histories, row transitions and accessibility.
- Settings: appearance first, monitoring and permissions remain functional; accurately describe refresh and fixed main-disk status icon.
- CPU, Memory, Network, My Mac, permission guide and iPhone portal keep their implemented features and real data. The mock does not authorize fake telemetry, QR codes, iPhone storage, changed service security or removal of recovery safeguards.
- Cleanup uses existing verified candidate/recovery workflow; the mock's simplified Trash copy does not replace actual deletion/recovery semantics.

## Global constraints

- No app installation, launch, login registration, notification request, commit or push as part of implementation.
- Test deletion only in temporary fixtures. Preserve 8-hour idle checks, active-use block, symlink/path validation and recovery.
- No global capacity total: APFS shared free space must not be added multiple times.
- Preserve failed/unavailable mounts and prevent old background results from overwriting newer state.
- `make verify` is the required final Release build/self-test/bundle check.

## Review focus

- APFS aliases, quotas and unconfirmed topology: show capacity per volume, annotate known sharing, never infer a total.
- Disconnect/reconnect while refreshing or exploring: selection and results must refer to the mounted identity actually scanned.
- Permission denied, symlinks, nested mounts and partial scan: report exclusions and keep traversal within the selected boundary.
- Large volume lists and long names: bounded popover and scrollable dashboard, keyboard-accessible row actions.
- Main status icon and destructive cleanup behavior must remain unchanged.

## Tasks

- [x] 1. Add read-only `StorageVolume` catalog, pure grouping/selection tests, asynchronous refresh and mount-change invalidation in `StorageController`.
- [x] 2. Add bounded, cancellable `StorageExplorer` folder measurement with temporary-directory tests for symlinks, partial results and cancellation.
- [x] 3. Apply shared volume rows/detail/explorer to Storage and Overview; add all-volume disclosure to menu summary; align Settings with reviewed order and factual refresh copy.
- [x] 4. Run `make verify`, render affected native content in light/dark and narrow/wide layouts, independently review current diff, resolve findings and record evidence.

## Execution notes

- Starting branch: `task/storage-ui-design`, base `3d7a1c2`; clean tracked tree.
- Existing checked-out project is reused. User requested implementation of an approved design; no further design gate is required.
- No new all-disk aggregate or automatic volume switching is introduced.

## Completion evidence

- Final `make verify`: PASS, `build/logs/verify-release-20261025-143852.H6vEyW`.
- Independent review: four P2 findings reproduced and fixed; regression logs in `build/logs/storage-ui/`.
- Native SwiftUI content renders inspected for narrow/wide dashboard and normal/large light/dark menu content. ScrollView uses the established static-content render path; no claim of installed-app GUI validation.
- Scope and evidence details: `docs/STORAGE_UI_VALIDATION.md`.
- No install, commit, push or user-file cleanup performed.
