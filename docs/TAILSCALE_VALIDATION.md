# Tailscale / My Mac validation

Source, build, local installation and release artifact verification record, updated 2026-10-25 KST. The observed-setup patch is unreleased; the September installation/release observations refer to the earlier baseline. Physical iPhone/iPad connection remains unverified. Paths under `build/` identify local evidence; those logs and screenshots are not shipped as release assets.

## Current status — 2026-10-25

The full working-tree app, including this setup patch, was installed during the menu-bar work. See [menu-bar validation](MENU_BAR_VALIDATION.md) and `build/logs/menu-summary/shared-transition-install.log`. This installs RetroStats; it does not prove that the new Tailscale authorization/install flow has run successfully. General verification passed in `build/logs/verify-release-20261025-115917.8fd4A3`.

Native authorization, privileged installation, extension/VPN approval, sign-in and physical-device E2E remain unverified for this patch. The September machine-state observations below are historical and have not been refreshed. No Tailscale reinstall, reboot or credential change was performed for this documentation update. No new release artifact was published.

The staged Tailscale changes on top of the storage commit also passed `make verify` in an isolated export. [Commit verification log](../build/logs/tailscale-commit-verify-20261025.log). This includes injected setup regressions, not real administrator authorization or installation.

## Historical observed-setup implementation — 2026-09-30 (unreleased)

**Final `make verify`: PASS.** [Full log](../build/logs/verify-release-20260930-234943.WVQjl5), [driver output](../build/logs/tailscale-setup-final-20260930.log). Release build, existing regressions, new setup tests and bundle/signature/arm64 checks passed. The bundle remains **1.3.0 (8)**; this patch has not been installed, committed, pushed or released by the implementation session. [Source/bundle SHA-256 manifest](../build/tailscale-setup-final-snapshot-20260930.json) records the exact dirty checkout and all bundle files. The user's separate dirty icon files are outside this patch's ownership and were preserved in place.

New meaningful regressions cover:

- Exact vendor extension identity, enabled status versus stale onboarding, VPN-stage separation and pending removal before an app exists.
- Installed-help configure gating, App Store/Standalone boundaries, `TAILSCALE_BE_CLI=1`, and `Unsupported` despite exit zero remaining pending.
- Native authorization script and both shell layers **compiled/parsed only**, including punctuation in package paths. No authorization or package payload was executed.
- macOS `lockf` contention and release on a **user temporary lock file**, with only sleep/echo commands: a competing payload cannot run. The privileged production lock/install remains unverified on the real machine.
- Cancelled/denied authorization, eight rapid Resume calls producing one reconciliation and no additional prompt, persisted live/unknown authorization, restart recovery and no generic handoff success.
- Finished/failed/interrupted jobs with an unconfirmed partial app cannot execute its CLI, advance to normal setup or silently replace it. Verified read-back resumes the existing client; a removed partial app offers one serialized retry.
- Job clearing stops polling when Network/mobile/access are inactive. Setup fixture collectors, temporary packages and isolated preferences suites are cleaned.
- Known regular vendor wrapper resolves to its app variant without execution; an orphan wrapper is ignored, while actual CLI binaries and custom launchers remain preserved.

**Offscreen render:** [80 PNG / 4 HTML artifacts](../build/tailscale-setup-review-20260930/), including 16 new minimum-width light/dark stage captures; [full log](../build/logs/tailscale-setup-render-20260930.log). Authorization, installing, confirmation, extension, VPN, sign-in, attention and reboot surfaces retain the accepted dot graphics and short English copy. The host receives the dashboard palette and captures a settled frame after an offscreen warm-up. These are layout/content fixtures; they do not prove real native authorization, focus, VoiceOver, installation or device connection.

Selected stage artifacts: [authorization dark](../build/tailscale-setup-review-20260930/tailscale-fixtures/setup-authorize-dark-minimum.png), [extension light](../build/tailscale-setup-review-20260930/tailscale-fixtures/setup-extension-light-minimum.png), [failed confirmation dark](../build/tailscale-setup-review-20260930/tailscale-fixtures/setup-failed-dark-minimum.png), [reboot light](../build/tailscale-setup-review-20260930/tailscale-fixtures/setup-reboot-light-minimum.png).

The intermediate [232656.0QGFlP](../build/logs/verify-release-20260930-232656.0QGFlP) build succeeded but its basic-connect fixture failed: a Standalone extension prerequisite had been applied without an app path. The GUI-only boundary was corrected; the final run above preserves that regression and passes. Final warnings are the existing macOS Keychain deprecations and AppIntents metadata warning; the new concurrent-capture warning was removed.

## Historical native evidence and outstanding validation

The leader observed the earlier real **Tailscale 1.102.4** installation through Installer. [Bundle/signature/receipt record](../build/logs/tailscale-1.102.4-real-install-20260930.json). That observation predates this patch and does not prove its new authorized install path. The extension subsequently became enabled while the old onboarding UI still required approval. During removal, `configure mac-vpn uninstall` returned `Unsupported on this app variant` with exit zero; extension deactivation was only a submitted request. [Command output](../build/logs/tailscale-configure-uninstall-20260930.log).

The September 30 leader handoff reported `/Applications/Tailscale.app`, `/Library/Tailscale` and `/usr/local/bin/tailscale` absent, an empty VPN service list, and the exact vendor extension still **terminated waiting to uninstall on reboot**. The trashed app remains; no Trash purge or reboot was performed by this session. The [21:31 audit](../build/logs/tailscale-uninstall-current-20260930.json) is older and must not be used to claim the wrapper remains. [Vendor user-state removal](../build/logs/tailscale-user-state-removal-20260930.json) is separately recorded. Backup copies were removed at the user's request; [audit](../build/logs/backups-removed-20260930.json). No new backups are part of this patch.

Required independent native checks, owned by the leader:

1. Run the exact built bundle and inspect **Restart Mac required** against the real pending-removal row. Verify it cannot download, prompt or install a duplicate. Preserve Keychain consent as an explicit user action if the saved hub blocks entry.
2. After the user's chosen reboot, confirm removal is actually complete, then use RetroStats **Install connection app**. Observe one administrator prompt; cancellation/denial must remain retryable. Opening a window must not count as installed.
3. Authorize installation once and verify root execution, installed bundle/Team/signature/receipt read-back and automatic progression. Try rapid resume/reentry and app restart without generating parallel prompts or cancelling an authorized package operation.
4. Follow extension/VPN handoffs. Confirm actual extension/configuration/backend state, including the known stale onboarding and unsupported-command cases; no submitted request alone may advance the stage.
5. Sign in and observe live connection plus hub readiness, then validate the same-account iPhone/iPad path and actual service use. Native keyboard/VoiceOver, Wi-Fi/cellular, sleep/wake and saved-link return remain separate checks.

Fresh-state authorized installation, native OS permissions, account sign-in and physical device E2E remain **unverified**. No reboot or real networking/credential mutation was performed by the implementation session.

## Delivered source

- Network now starts with **MY MAC** and an opt-in preparation flow. Complete Tailscale controls remain in Advanced management: distributions/status/preferences, peers/favorites/addresses/accounts, diagnostics, tunnel/peer metrics, Taildrop, Serve/Funnel, Exit/subnet advertisement and optional administration.
- `MacAccessCoordinator` owns the persistent hub, saved port/endpoint/account boundary, separate Keychain token, source identity, cancellation/generation and reconnect/wake/restart behavior. The 15-minute LAN setup session is independent. Explicit incoming allowance changes only `shields-up`; Disconnect/Log out pause automatic connection.
- The exact Tailscale address is the persistent listener's binding. A token alone does not expose its service actions: the request source must identify a visible, same-owner, untagged iOS peer, or the user must resolve an owned ambiguous match on the Mac. Other/unknown sources receive the checking page. No arbitrary device is authorized.
- `MacAccessProbe` checks configured ports only: SSH/VNC banners, SMB negotiate response and HTTP service response. Authentication/use remain separate. Only an explicitly selected localhost web service can be proxied, and its target/port/path/scope plus unrelated settings are verified before adding a shortcut.
- `TailscaleInstaller` constrains official HTTPS download sources, verifies the vendor signature/Gatekeeper assessment, then drives one-shot package installation after normal native administrator authorization. A root-owned package copy is rechecked against SHA-256/signature/Gatekeeper, root job markers/locking serialize execution, and installed bundle/receipt/signature determine completion. An existing distribution is preserved. OS extension/VPN consent and account sign-in remain separate observed stages.
- English One Step instructions use actual RetroBitmapA and the design session's square dot matrices. No preview timer, simulated OS approval, mock QR or Tweak controls are used in production. Instructional cards do not prove installation/sign-in/permission; real HTTP requests determine path progress. Prepared services refresh automatically on the reusable hub.

## Build and self-tests

**Released baseline PASS:** `make verify` against the released **1.3.0 (8)** Swift source, [full log](../build/logs/verify-release-20260930-202145.sTzVC5). The earlier implementation verification is preserved at [193753.SyW9JT](../build/logs/verify-release-20260930-193753.SyW9JT). The current unreleased patch is recorded separately below.

The check includes Release compilation, existing Swift regressions, bundle/signature/architecture checks and new Tailscale regressions:

- Distribution detection using temporary bundles/receipt/symlink fixtures; command capability and missing/changed JSON fields.
- Isolated tunnel counter deltas/reset/account changes; physical `en*` totals remain separate.
- Partial preference read-back, settings preservation, cancellation and stale/external account delivery.
- Concurrent stdout/stderr pipe burst, timeout, cancellation and output limits with test executables.
- Mock administrator 401/403/409/412, policy validation/ETag conflict, selected-device authorization, key expiry/session races/revoke and secret exclusion.
- Temporary LAN/Tailscale separation, automatic source matching, token/path/method/expiry/close behavior.
- Persistent hub opt-in, same-owner identity/content filtering, actual service URLs, restart/wake endpoint reuse, authentication expiry/account/port conflict, retry/reissue/off, paused disconnect and stale probe completion.
- Basic connect/read-back without automatic routes/Exit Node/Serve/Funnel changes; explicit incoming allowance preserves preexisting subnet advertisement.
- Real **loopback-only** Network listener and HTTP response/denied path/CSP script hash. No actual Tailscale address is bound by self-tests.
- Trusted macOS package signature output, wrong signing team, revoked/untrusted status and non-leaf identity rejection.
- Dashboard lifecycle with enabled My Mac uses an injected inert controller; protected saved-link restore/polling use noninteractive credentials and preserve both preferences and token on denial.

The final self-tests use injected CLI/API/server/credential/probe fixtures. They do not run the installed Tailscale client, contact the administrator API, touch real Keychain credentials, install packages, modify VPN/sharing/routing settings, or delete real DerivedData. An earlier interrupted self-test reached real Keychain through a production DashboardModel; the dependency injection fix and its regression are recorded below.

Build output: `build/RetroStats.app`, installed and launched as described below. No Swift errors remained. Warnings include the existing AppIntents metadata extraction warning and deprecated file-based Keychain interaction-policy APIs. The latter are retained for the app's existing macOS file-based credentials; a lock serializes credential operations and restores the prior interaction policy after noninteractive reads. See [Apple's macOS Keychain implementation distinction](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

## Native layout artifacts

**PASS:** `--render-dashboard` produced **64 PNGs and 4 HTML files** in [my-mac-review-20260930](../build/my-mac-review-20260930/). [Full render log](../build/logs/my-mac-render-20260930.log).

The matrix includes 360/400/840pt, light/dark, normal/large panel text, long device names and connection states. Helpers/management use an offscreen NSHostingView; dashboards use ImageRenderer. CLI/API/listener startup is disabled in these render fixtures. Final minimum-width helper, large dark panel, minimum/wide management and mobile setup/hub exports were visually inspected.

Selected artifacts:

- [English Mac helper, minimum](../build/my-mac-review-20260930/tailscale-fixtures/mobile-en-light-minimum.png)
- [Large dark MY MAC panel](../build/my-mac-review-20260930/tailscale-fixtures/panel-large-dark-minimum.png)
- [English mobile setup](../build/my-mac-review-20260930/tailscale-fixtures/mobile-setup-en.html)
- [Reusable My Mac hub](../build/my-mac-review-20260930/tailscale-fixtures/my-mac-en.html)
- [Unverified-source page](../build/my-mac-review-20260930/tailscale-fixtures/my-mac-unverified-en.html)

These prove content/layout rendering, not a live native window's keyboard/VoiceOver behavior or a physical phone connection. Fixture addresses/QRs are not onboarding destinations for a real device.

## Browser fixture

**PASS: 58 checks, zero JavaScript errors.** [Result JSON](../build/my-mac-browser-review-20260930/verification.json), [full log](../build/logs/my-mac-browser-review-20260930.log), [reproduction script](../build/verify-my-mac-browser.cjs).

Generated production HTML was served on loopback to isolated headless Chrome. All external destinations were blocked or mocked; no App Store/VPN/real mobile connection was exercised. Checked 320/390/680px light/dark layouts, bundled bitmap font, English-only content and keyboard focus; Files copy guidance rather than an invented app-launch URL; unprepared-service filtering; failure/retry; HTTP reachability insufficient for owner confirmation; automatic identity recovery and correct saved-page title; selected-task retention; disappeared-service removal and offline action hiding.

[Browser screenshots](../build/my-mac-browser-review-20260930/) include setup/hub for all widths/themes, setup failure and disconnected hub. Clipboard paste into Files or another mobile app is not verified by these DOM checks.

The separate design task's preview validation (94 checks) is a design-only result and is not included in the 58 product-HTML checks above.

## Earlier native fixture GUI attempt

Before local installation, the isolated `--show-tailscale-fixture` window was started without production services. Computer Use failed first with `native pipe closed`, then with `-10005 timeoutReached`. [Full returned error records](../build/logs/tailscale-native-ui-attempts-20260930.log). The fixture process was subsequently confirmed exited. That fixture attempt did not terminate or replace the user's installed app.

**Not verified:** native keyboard traversal, focus behavior and VoiceOver announcements. Source labels, native controls and Escape dismissal were inspected; browser keyboard/ARIA checks do not substitute for the native runtime checks. No blind retry or alternate event injection was used after the backend failures.

## Local installation and release artifact: 1.3.0 (8)

- The earlier **1.2.1 (7)** backup and all other app/user-state backup copies were deleted at the user's request; they are no longer available. [Removal audit](../build/logs/backups-removed-20260930.json). No new backup was made by the setup implementation. The released baseline replaced `~/Applications/RetroStats.app` with its preferences and credentials preserved. [Installation log](../build/logs/install-retrostats-1.3.0-final-20260930-202335.log), [artifact and installation metadata](../build/releases/v1.3.0/install-final-metadata.json).
- Source, installed and ZIP-extracted bundles match across all 8 regular files. Each passed strict code-signature verification. Version/build and bundle identity were checked; the installer Makefile now copies `build/RetroStats.app` rather than the stale `build/MiniStats.app` path.
- Final production AppDelegate launch and native Overview/Network navigation were observed. [Installed Network screenshot](../build/logs/retrostats-1.3.0-installed-network.png), [accessibility snapshot](../build/logs/retrostats-1.3.0-installed-network-ax.txt). A saved link requiring new Keychain approval reports **LINK UNAVAILABLE** while the dashboard remains responsive. Continue setup is the explicit interactive recovery path. Keychain permissions were not granted by this verification.
- The actual official `Tailscale-1.102.4-macos.pkg` was downloaded for diagnosis. Both `pkgutil --check-signature` and `spctl --assess --type install` exited 0; the leaf is `Developer ID Installer: Tailscale Inc. (W5364U7YZB)` and Gatekeeper reports accepted / Notarized Developer ID. [Signature output](../build/releases/v1.3.0/pkgutil-signature.log), [Gatekeeper output](../build/releases/v1.3.0/spctl-assessment.log). The parser now accepts the observed Apple distribution status while retaining the required Team ID and separate Gatekeeper assessment. The package was not installed during this verification.
- Release assets: `RetroStats-1.3.0-macOS.zip` and `SHA256SUMS.txt`. ZIP SHA-256: `502f093e7f4c90e3b90286dc9ec0c35edac2e8fcb98a91358f240f177929060a`. The app is arm64 for macOS 26+, ad-hoc signed and not notarized. [GitHub v1.3.0 release](https://github.com/oozoofrog/MiniStats/releases/tag/v1.3.0).

These checks prove local installation, responsive production GUI and artifact identity. They do not prove a Tailscale VPN connection, mobile access or a service login.

## Real device validation still open

No Tailscale client was found at the checked standard app/CLI locations at implementation start. RetroStats installation is complete; Tailscale installation/account login, mobile registration and service use remain separate. This verification did not register a mobile device, grant Keychain/VPN access, change real sharing/routing or exercise administrator credentials.

The following require the user's actual account/device/system prompts:

| Evidence lane | Remaining check |
| --- | --- |
| Installer/Keychain | Installer completion, OS approval, installed-client detection and authorized real token/API Keychain read/write; package signature/Gatekeeper assessment is complete |
| Mac runtime | Native keyboard/VoiceOver, listener/firewall/local-network consent and actual connection/authentication recovery; production GUI launch/navigation is complete |
| iPhone and iPad | Same-account login/VPN permission, Safari source matching and permanent saved link on each platform |
| Advanced enrollment | Optional auth-key entry, actual selected-device/route authorization, credential expiry and policy conflict |
| Services | Real SMB file or web action, compatible SSH/VNC app handoff/host-key/sign-in, service policy/firewall reachability |
| Mobility/lifecycle | Wi-Fi→cellular, Mac sleep/wake, app restart, offline and login expiry using the saved link |
| Exit Node | Explicit mobile selection/None and external IP comparison before/after; separate from My Mac access |

The unavoidable first actions are app installation, account sign-in and OS VPN approval. Sharing users/folders and service-specific credentials remain in macOS/the relevant app. No “fully automatic mobile connection succeeded” claim is made without these real-device results.

## Resolved verification failures

Full failed logs are preserved; all causes below were corrected before the final PASS.

| Full log | Failure / correction |
| --- | --- |
| [173137.b2TJTY](../build/logs/verify-release-20260930-173137.b2TJTY) | MainActor access and state wrappers; corrected actor boundary/declarations |
| [173219.2E6vMf](../build/logs/verify-release-20260930-173219.2E6vMf) | Multiple state-wrapper declarations; split into simple properties |
| [173733.ORjRvr](../build/logs/verify-release-20260930-173733.ORjRvr) | Async actor access inside test autoclosure; awaited before assertion |
| [173823.3oUrZ6](../build/logs/verify-release-20260930-173823.3oUrZ6) | Fixture counted help queries as settings replacement; excluded `--help` |
| [184738.VOeYSo](../build/logs/verify-release-20260930-184738.VOeYSo) | Redirect delegate local argument name mismatch; corrected identifier |
| [190719.OQl236](../build/logs/verify-release-20260930-190719.OQl236), [191035.k1PzSa](../build/logs/verify-release-20260930-191035.k1PzSa) | New basic-connect fixture also counted help as mutation; diagnostics showed Connected/Mac ready with only help/status/up calls, and predicate was corrected |
| [200539.f2Io12](../build/logs/verify-release-20260930-200539.f2Io12), [self-test sample](../build/logs/release-1.3.0-selftest-sample.txt) | Compilation passed but the self-test reached real Keychain through the default DashboardModel and waited for authorization. The identified test process was stopped with SIGTERM; this is an interrupted run, not PASS. Dashboard tests/rendering now inject inert controllers and scoped defaults; the final full verification passed with the user's My Mac setting still enabled |
| [Intermediate production launch sample](../build/logs/retrostats-1.3.0-final-launch-sample.txt) | Startup restored the saved link using a synchronous interactive Keychain read, blocking the dashboard. Restore/polling now fail closed without interaction and retain the existing record/token; the subsequent final installed build opened and navigated successfully |

Early ImageRenderer-only native forms were empty; later shader-rendered offscreen form text overlapped. Those artifacts were superseded by NSHostingView capture plus direct bitmap form text drawing. Earlier render logs remain under `build/logs/tailscale-render*.log`; final artifacts are under `build/my-mac-review-20260930`.


## Native validation — 2026-10-25

Existing `/Applications/Tailscale.app` is version 1.104.2. Strict code-signature verification passed with bundle ID `io.tailscale.ipn.macsys` and Team `W5364U7YZB`. The package receipt exists but reports 1.102.4; it is historical, not proof of the new installer path. Evidence: `build/logs/native-validation-20261025/signature.txt`, `receipt.plist`.

Live CLI reports Running, Self Online, an assigned address and no Health warnings. System VPN is Connected. Extension 1.104.2 is activated/enabled while 1.104.1 remains terminated waiting to uninstall on reboot. The existing installation was preserved; no uninstall, reinstall or reboot was performed. This does not validate fresh installation through RetroStats. All six registered peers were offline at the initial sample, including four same-owner iOS peers.

The installed RetroStats executable matched the working-tree build. The real Network → Continue setup flow opened native Keychain authorization. After that dialog closed, My Mac displayed “Access link could not bind its saved address/port.” The requested service path therefore FAILS before a phone can load the hub. A BSD bind to the same live address/port succeeded. An isolated Swift reproduction of the production `NWListener(using: parameters, on: localPort)` with `requiredLocalEndpoint` set failed synchronously with POSIX EINVAL. See [listener reproduction](../build/logs/native-validation-20261025/listener-check.log). The same parameters with `NWListener(using: parameters)` constructed successfully; [comparison log](../build/logs/native-validation-20261025/listener-alternative.log). This comparison verifies construction only, not listening or remote access. No saved link or credentials were replaced.

Physical-device HTTP access and service use remain unverified. This validation did not change source implementation, approve system dialogs, or publish a release. Raw status evidence is local only because it contains network/device identifiers.


### Physical iPhone transport check — 2026-10-25

After the user connected `iphone-14-pro-1`, the matching DNS peer reported iOS, Online and the same UserID as this Mac. Its CLI HostName was `localhost`, so matching used the DNS label supplied by the user. A one-packet `tailscale ping` to the peer completed with exit 0. Evidence: `build/logs/native-validation-20261025/status-iphone-connected.json` and `iphone-ping.log`. This proves peer transport reachability, not a successful HTTP hub load or service use. The RetroStats listener EINVAL blocker remains. The user reported no security prompt was open; no additional approval was requested.


## Saved-port listener correction — 2026-10-25

Added a real loopback regression for a nonzero saved port, checking the exact bound port, HTTP 200 response and wrong-path HTTP 404. The old implementation built successfully but the new regression failed with POSIX EINVAL: [RED log](../build/logs/verify-release-20261025-123348.TN3IT4).

`requiredLocalEndpoint` now supplies both address and port, without also passing `on:` to `NWListener`. Full `make verify`, including ephemeral and fixed-port socket regressions, passed: [GREEN log](../build/logs/verify-release-20261025-123441.nbDhiZ). The corrected bundle was installed with the same designated requirement and byte-matched to the build: [installation log](../build/logs/native-validation-20261025/listener-fix-install.log).

The installed GUI progressed to MAC READY and opened the device QR without regenerating the saved address or port. This confirms listener readiness, not physical-device HTTP completion. Direct host-to-own-Tailscale HTTP probing timed out; the application firewall reports RetroStats permitted and block-all disabled. Physical-device response is being verified separately.


## Final bound-server correction and physical hub check — 2026-10-25

Removing the duplicate NWListener port fixed construction, but was not sufficient: both the app and a separate minimal Network.framework listener still timed out on the Tailscale interface, while a BSD-bound temporary HTTP server delivered HTTP 200 to the actual iPhone. The host firewall reported both apps permitted. This is observed behavior on this macOS 27.0.1 host, not a general claim about Network.framework.

The final `MobileGuideServer.swift` uses nonblocking BSD sockets bound to one explicit numeric IPv4/IPv6 address. It rejects wildcard/DNS addresses, preserves the saved port, and retains GET/token/expiry checks, 8192-byte request limit, eight-client limit, five-second deadlines, device identity filtering and response security headers. Partial output uses a write source. Shared-FD close waits for both read/write sources to finish cancellation. Transient ECONNABORTED does not stop the listener. Off-queue stop waits for FD closure before saved-port restart. No Tailscale policy, firewall setting, saved token or address was changed.

Independent read-only review identified the transient accept-error and FD cancellation issues above; both were fixed and re-reviewed with no remaining concrete source findings. Full [make verify](../build/logs/verify-release-20261025-124831.9qM4dw) passed, including exact-address/fixed-port HTTP, wildcard and occupied-port rejection, wrong-path protection and immediate fixed-port restart. Earlier integration attempts exposed an IPv6 struct comparison compile error and a Swift exclusivity compile error, both corrected. A separate earlier run failed an existing CLI typed-failure expectation before the guide tests; the unchanged binary passed on rerun. The assertion now prints expected/actual failures, and the final full check passed.

[Installation](../build/logs/native-validation-20261025/bound-server-install.log) passed the stable certificate requirement and installed bytes matched the built executable. The real Tailscale endpoint returned [HTTP 404](../build/logs/native-validation-20261025/live-bound-endpoint.txt) for an invalid link. The native LAN guide returned HTTP 200, and its persistent My Mac destination was presented as a QR to the user.

The user confirmed that My Mac opened on `iphone-14-pro-1`. The installed app independently changed to “Device connection checked” and “localhost can reach My Mac.” The peer's DNS name is `iphone-14-pro-1` while its reported HostName is `localhost`. [Redacted native observation](../build/logs/native-validation-20261025/iphone-hub-observation.json). The selected device is the same-account iOS peer, not the Mac's own loopback request. A service click from that page is checked separately.


### Physical service completion

The user then opened Web from the actual My Mac page and confirmed the success page/code `RS-6427`. The temporary service independently logged HTTP 200 for `/` from the `iphone-14-pro-1` peer at 2026-10-25 03:51:58 UTC. This is separate from the earlier direct-service diagnostic at 03:40:30 UTC. The final peer snapshot and request log are local evidence at `build/logs/native-validation-20261025/status-final.json` and `web-requests.jsonl`. The actual flow verified is iPhone → RetroStats My Mac hub → configured HTTP service. SSH, SMB and VNC authentication/use were not tested because those services were not running.

The user-authorized temporary Python service served only synthetic verification HTML, bound to the Mac's Tailscale IPv4 at port 8080. It was terminated after success and connection refusal confirmed closure. No sharing/VPN/firewall setting was changed, and no persistent web service was installed. The normal My Mac hub remains available while RetroStats runs; its Web action will become unavailable after the next service probe because the temporary service has ended. Fresh Tailscale installation, physical sleep/wake and Wi-Fi/cellular handoff remain separate unverified cases.
