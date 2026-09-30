# My Mac access

Start at **Network → MY MAC → Start access**. The helper uses short English instructions and dot graphics. RetroStats prepares the connection, finds your device, builds service addresses, and retries when your Mac reconnects. If incoming connections were blocked, **Allow Mac access** changes only that setting after your explicit action.

## First time

1. If needed, choose **Install connection app** on the Mac. RetroStats obtains the official Tailscale package, checks its trusted Tailscale installer signature and Gatekeeper assessment, then opens Installer. Complete Installer and the macOS approval/sign-in prompts. An existing Mac distribution is preserved.
2. Scan **Mobile Guide** with your iPhone or iPad. Install Tailscale, sign in with the displayed **Sign-in account**, and allow its VPN configuration. This is your Tailscale identity, not your Mac local login.
3. Return to the guide. It automatically tries the Mac link. **Open My Mac** is also available if the browser blocks the automatic check. Instruction cards do not certify that an app was installed or an OS prompt was approved.
4. Save **My Mac** as a bookmark or use Safari **Share → Add to Home Screen**. Use the same saved link next time.

The first guide is available on the Mac's current Wi-Fi network and expires after 15 minutes. If you are already on another network, use **Get the connection app**, sign in and allow VPN, then scan **Open My Mac**. No administrator API or auth key is required for the normal same-account flow.

RetroStats identifies an iPhone/iPad only after observing its request at the Mac's Tailscale address and matching exactly one visible, untagged mobile device owned by the same Tailscale user. Multiple or hidden identities can require a device choice or administrator help. No new device is approved automatically. A visible/online device, QR scan or local Mac probe alone does not confirm the phone path.

## Use your Mac

My Mac shows only services that respond on the Mac's connection address. Choose the purpose you want to prepare on the Mac; **Prepare a Mac service** opens sharing settings only for that choice. Select sharing folders and allowed users in macOS yourself.

| Purpose | Mobile action | Remaining requirement |
| --- | --- | --- |
| Files | Copy the address. In Files: Browse → … → Connect to Server, then paste. | File Sharing/SMB and an allowed Mac user. Verify by opening a file. |
| Mac Screen | Open the generated VNC link in a compatible app, or copy its address. | An iPhone/iPad VNC app, Screen Sharing and an allowed Mac user. Verify the actual screen. |
| Terminal | Open the generated SSH link in a compatible app, or copy its address. | An iPhone/iPad SSH app and Remote Login. Check the host key, then sign in. |
| Web | Open the prepared web app in Safari. | The web app may require its own sign-in. |

If a configured web app responds only on this Mac, **Share this web app** can proxy just that selected service to permitted devices. Review the confirmation. This does not publish it to the internet. Add a custom web app in **Advanced → Device service shortcuts**; only configured ports are checked.

Mac service credentials belong in Files or the chosen SSH/VNC/web app. The helper never collects a Mac password. A responding listener is preparation evidence; actual sign-in and service use remain separate.

## Next time and recovery

Keep the Mac awake and RetroStats running. Open the saved My Mac link; setup is not repeated. The Mac restores the same port and Keychain link token after app restart, rebinds after wake, and retries connection when access remains enabled. The open hub refreshes service availability automatically; loss of its path hides stale actions and shows the next recovery instruction.

For mobile reconnection, Tailscale provides [VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand). Its enabled client already maintains a reconnect policy; optional customized rules can use **Always** for Wi-Fi and cellular. Another VPN may disable On Demand until Tailscale is reconnected. RetroStats cannot change these mobile settings from the Mac.

If login expires, sign in again in the official app. If the saved port is busy or the link token is unavailable, use **Access link controls → Reissue access link**; save the replacement on the phone. Reissuing invalidates the old link. **Turn off Mac access** stops the hub and deletes its record/token; Mac sharing and Tailscale routing preferences are preserved. An explicit Disconnect/Log out in Advanced pauses automatic connection until Continue.

A changed Tailscale account cannot inherit the old link. Reissue it for the new account. Normally the numeric Tailscale endpoint is stable for the node and also works when a mobile client does not accept MagicDNS. If that address changes, update the saved link.

These service actions provide remote access to your Mac. They do not turn mobile localhost into Mac localhost, recreate Bonjour discovery, or give every device the same LAN address.

## Advanced management

**Advanced management** retains the complete Tailscale tools: connection/Disconnect/Log out, current installation/account/address/health, peer list/favorites/copy/diagnostics, accounts/switch, partial DNS/route/Exit Node preferences, separate tunnel and peer metrics, Taildrop, per-entry Serve/Funnel and custom service shortcuts.

Exit Node and subnet advertisements are optional, explicit operations. They are not part of ordinary My Mac access. Select or clear an Exit Node in the mobile Tailscale app yourself and verify external IP changes separately. RetroStats does not clear an Exit Node on failure.

The optional administrator view supports selected-device authorization, route approval, tailnet DNS, and policy validation/comparison/ETag conflict handling. API credentials are kept in a separate Keychain item. The advanced mobile helper offers same-tailnet one-use auth keys: no tags, non-ephemeral, at most ten minutes, optional preauthorization, explicit display/copy on the Mac, expiry/disposal and revoke attempt on closing. Keys/API credentials are never included in the guide or QR.

Serve is limited to permitted tailnet devices; Funnel is public internet sharing and requires its own confirmation. Existing unrelated settings are checked for preservation. Unsupported distribution/CLI commands show alternatives. Tunnel metrics remain separate from physical network totals.

## Evidence

The implementation and fixture/build results are in [the validation record](TAILSCALE_VALIDATION.md). A working design preview or passing self-test is not an iPhone/iPad connection result.

Official references: [Mac installation](https://tailscale.com/docs/install/mac), [iOS installation](https://tailscale.com/docs/install/ios), [VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand), [macOS variants](https://tailscale.com/docs/concepts/macos-variants), [CLI](https://tailscale.com/docs/reference/tailscale-cli?tab=macos), [auth keys](https://tailscale.com/docs/features/access-control/auth-keys), [Exit Nodes](https://tailscale.com/docs/features/exit-nodes?tab=ios), [Funnel](https://tailscale.com/docs/reference/tailscale-cli/funnel), [API](https://tailscale.com/api).
