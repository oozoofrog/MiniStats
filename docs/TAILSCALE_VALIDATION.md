# Tailscale / My Mac validation

2026-09-30 KST. Source, build, local installation and release artifact verification record. Physical iPhone/iPad connection remains unverified. Paths under `build/` identify local evidence; those logs and screenshots are not shipped as release assets.

## Delivered source

- Network now starts with **MY MAC** and an opt-in preparation flow. Complete Tailscale controls remain in Advanced management: distributions/status/preferences, peers/favorites/addresses/accounts, diagnostics, tunnel/peer metrics, Taildrop, Serve/Funnel, Exit/subnet advertisement and optional administration.
- `MacAccessCoordinator` owns the persistent hub, saved port/endpoint/account boundary, separate Keychain token, source identity, cancellation/generation and reconnect/wake/restart behavior. The 15-minute LAN setup session is independent. Explicit incoming allowance changes only `shields-up`; Disconnect/Log out pause automatic connection.
- The exact Tailscale address is the persistent listener's binding. A token alone does not expose its service actions: the request source must identify a visible, same-owner, untagged iOS peer, or the user must resolve an owned ambiguous match on the Mac. Other/unknown sources receive the checking page. No arbitrary device is authorized.
- `MacAccessProbe` checks configured ports only: SSH/VNC banners, SMB negotiate response and HTTP service response. Authentication/use remain separate. Only an explicitly selected localhost web service can be proxied, and its target/port/path/scope plus unrelated settings are verified before adding a shortcut.
- `TailscaleInstaller` constrains index/package URLs and redirects to official HTTPS package hosts, requires trusted Tailscale installer signature/Team ID and Gatekeeper assessment, rechecks existing-client detection, and opens Installer. It does not approve installation or replace a detected distribution.
- English One Step instructions use actual RetroBitmapA and the design session's square dot matrices. No preview timer, simulated OS approval, mock QR or Tweak controls are used in production. Instructional cards do not prove installation/sign-in/permission; real HTTP requests determine path progress. Prepared services refresh automatically on the reusable hub.

## Build and self-tests

**PASS:** `make verify` against the final **1.3.0 (8)** Swift source, [full log](../build/logs/verify-release-20260930-202145.sTzVC5). The earlier implementation verification is preserved at [193753.SyW9JT](../build/logs/verify-release-20260930-193753.SyW9JT).

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

- The original installed **1.2.1 (7)** bundle was backed up at `build/install-backups/20260930-195955/RetroStats.app`. The final build replaced `~/Applications/RetroStats.app` with its preferences and credentials preserved. [Installation log](../build/logs/install-retrostats-1.3.0-final-20260930-202335.log), [artifact and installation metadata](../build/releases/v1.3.0/install-final-metadata.json).
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
