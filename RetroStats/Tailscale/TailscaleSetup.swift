import Foundation

enum TailscaleSetupStage: String {
    case install = "Install connection app", downloading = "Downloading", verifying = "Checking package"
    case authorizing = "Authorize installation", installing = "Installing", installationPending = "Checking installation"
    case extensionApproval = "Allow network extension", vpnApproval = "Allow VPN", signIn = "Sign in"
    case deviceApproval = "Approve this Mac", connecting = "Connecting", ready = "Mac connected"
    case unavailable = "Resume connection", cancelled = "Installation cancelled", failed = "Setup needs attention"
    case rebootRequired = "Restart Mac required"
    var detail: String {
        switch self {
        case .install: return "Install Tailscale here to connect your Mac."
        case .downloading: return "Getting the official connection app."
        case .verifying: return "Checking its signature and macOS approval."
        case .authorizing: return "Approve the macOS administrator prompt. Installation follows automatically."
        case .installing: return "Installing the verified app. Keep RetroStats open."
        case .installationPending: return "Reading the installed app and receipt before continuing."
        case .extensionApproval: return "Turn on Tailscale in Network Extensions, then choose Done."
        case .vpnApproval: return "Choose Allow in the macOS VPN prompt."
        case .signIn: return "Sign in in the opened connection app. We continue automatically."
        case .deviceApproval: return "Your administrator needs to approve this Mac."
        case .connecting: return "Waiting for your Mac’s connection."
        case .ready: return "Continue on your iPhone or iPad."
        case .unavailable: return "The app is installed. Resume its connection setup."
        case .cancelled: return "Choose Install to try again."
        case .failed: return "Check the message below, then resume setup."
        case .rebootRequired: return "macOS is finishing the previous removal. Restart your Mac, then resume here."
        }
    }
    var installInFlight: Bool { [.downloading, .verifying, .authorizing, .installing, .installationPending].contains(self) }
}

enum TailscaleExtensionState: Equatable { case unknown, absent, approvalRequired, enabled, removalPending }

/// Only the vendor's exact team and extension row constitutes extension evidence.
struct TailscaleSetupObservation {
    var extensionState: TailscaleExtensionState = .unknown
    var vpnPresent: Bool? = nil
    static func extensionState(_ output: String) -> TailscaleExtensionState {
        let rows = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            let fields = $0.split(whereSeparator: \.isWhitespace)
            return fields.contains("W5364U7YZB") && fields.contains("io.tailscale.ipn.macsys.network-extension")
        }
        if rows.contains(where: { $0.hasSuffix("[terminated waiting to uninstall on reboot]") }) { return .removalPending }
        guard rows.count == 1, let row = rows.first else { return rows.isEmpty ? .absent : .unknown }
        if row.hasSuffix("[activated enabled]") { return .enabled }
        return .approvalRequired
    }
    static func vpnPresent(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains {
            $0.contains("(io.tailscale.ipn.macsys)") || $0.contains("(io.tailscale.ipn.macos)")
        }
    }
    func stage(installation: TailscaleInstallation?, snapshot: TailscaleSnapshot) -> TailscaleSetupStage {
        if extensionState == .removalPending { return .rebootRequired }
        guard let installation else { return .install }
        // A live connected backend outranks stale frontend onboarding text.
        if snapshot.state == .connected, snapshot.local?.address.isEmpty == false { return .ready }
        if installation.variant == .standalone, installation.appPath != nil, [.absent, .approvalRequired].contains(extensionState) { return .extensionApproval }
        switch snapshot.state {
        case .signedOut: return .signIn
        case .deviceApproval: return .deviceApproval
        case .disconnected, .connecting: return .connecting
        case .extensionApproval:
            return extensionState == .enabled ? .vpnApproval : .extensionApproval
        default:
            if installation.appPath != nil, (extensionState == .enabled || installation.variant == .appStore), vpnPresent == false { return .vpnApproval }
            return .unavailable
        }
    }
}

extension TailscaleCapabilities {
    func configure(_ command: String, action: String) -> Bool {
        guard (command == "sysext" && variant == .standalone) || (command == "mac-vpn" && [.standalone, .appStore].contains(variant)),
              let help = help["configure " + command], !help.lowercased().contains("unsupported") else { return false }
        return help.range(of: "(?<![A-Za-z-])" + NSRegularExpression.escapedPattern(for: action) + "(?![A-Za-z-])", options: .regularExpression) != nil
    }
}
