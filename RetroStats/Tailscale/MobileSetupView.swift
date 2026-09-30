import AppKit
import SwiftUI

struct AdvancedMobileSetupView: View {
    @ObservedObject var controller: TailscaleController
    @ObservedObject var session: MobileSetupSession
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var preauthorized = false
    @State private var approve = false
    @State private var step = 0
    private var t: (String, String) -> String { session.language.text }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(t("iPhone·iPad 연결", "Connect iPhone or iPad")).font(.title2).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(t("종료", "Close")) { session.end(); if let onClose { onClose() } else { dismiss() } }.keyboardShortcut(.cancelAction)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(t("Mac 준비 → 모바일 설치·인증 → 본인 기기 선택 → 실제 연결 → 서비스 사용", "Prepare Mac → Install and sign in → Select your device → Verify path → Use services"))
                    GroupBox(t("1. Mac 준비", "1. Prepare this Mac")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(controller.snapshot.state.rawValue + " · " + controller.snapshot.account + " · " + controller.snapshot.tailnet).textSelection(.enabled)
                            HStack {
                                Button(t("공식 설치 안내", "Official installation")) { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!) }
                                Button(t("Tailscale 열기 / 로그인", "Open Tailscale / sign in")) {
                                    if let path = controller.installation?.appPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                                    else { NSWorkspace.shared.open(URL(string: "https://tailscale.com/docs/install/macos")!) }
                                }
                            }
                            Text(t("확장 승인은 시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램 → 네트워크 확장 프로그램에서 확인하세요.", "Check extension approval in System Settings → General → Login Items & Extensions → Network Extensions."))
                            Button(t("확장·VPN 승인 설정", "Extension / VPN settings")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!) }
                            Button(t("공유 설정: 파일·원격 로그인·화면 공유", "Sharing: files, Remote Login, Screen Sharing")) { openSharingSettings() }
                            Button(t("로컬 네트워크·방화벽 설정", "Local Network / firewall settings")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!) }
                            Text(t("Standalone과 App Store 버전을 동시에 설치하지 마세요. Mac 설치·확장 승인·VPN 구성·로그인은 직접 진행해야 합니다. 공유 폴더와 허용 사용자도 직접 선택하세요.", "Use one Mac distribution at a time. Installation, extension/VPN approval and sign-in require your action. Select sharing folders and allowed users yourself."))
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox(t("2. 모바일 설치·인증", "2. Install and sign in on mobile")) {
                        VStack(alignment: .leading, spacing: 12) {
                            qr(URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!, title: t("공식 App Store 설치 QR", "Official App Store installation QR"))
                            Text(t("iPhone/iPad에서 앱 설치·실행 → VPN 구성 허용 → Mac과 같은 계정으로 로그인하세요. 이 QR은 설치 링크입니다. Mac 로그인 QR을 모바일 등록 QR로 사용하지 않습니다.", "On iPhone/iPad: install and open the app → allow VPN configuration → sign in with the same account. This QR is an installation link. A Mac login QR does not enroll the phone."))
                            if controller.mobileAPIAvailable {
                                Toggle(t("인증키로 등록할 기기를 미리 승인", "Preauthorize the device enrolled with this key"), isOn: $preauthorized)
                                Button(t("일회용 인증키 발급 (10분)", "Create one-use auth key (10 minutes)")) { controller.createMobileKey(preauthorized: preauthorized) }.disabled(controller.busy || session.authKey != nil || !session.active)
                                if let key = session.authKey {
                                    Text(t("이 키는 10분 후 만료됩니다. Mac에서만 명시적으로 표시·복사하세요.", "This key expires after 10 minutes. Display/copy explicitly on the Mac only."))
                                    Button(session.keyVisible ? t("키 숨기기", "Hide key") : t("키 표시", "Show key")) { session.keyVisible.toggle() }
                                    if session.keyVisible { Text(key.secret).textSelection(.enabled).privacySensitive().accessibilityLabel(t("일회용 인증키", "One-use auth key")) }
                                    Button(t("인증키 복사", "Copy auth key")) { copy(key.secret) }
                                }
                            } else { Text(t("기본은 같은 계정 로그인입니다. 인증키·자동 승인은 Manage에서 관리자 API를 선택 연결한 경우에만 제공됩니다.", "Same-account login is the default. Auth keys and approval require the optional administrator API in Manage.")) }
                            if let url = session.lanURL { qr(url, title: t("등록 전: 같은 Wi-Fi 안내", "Before enrollment: same-Wi-Fi guide")) }
                            Text(session.serverMessage)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox(t("3. 본인 기기를 선택하세요", "3. Select your own device")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker(t("기기", "Device"), selection: Binding(get: { session.selectedID ?? "" }, set: { session.selectedID = $0.isEmpty ? nil : $0 })) {
                                Text(t("본인 기기 선택", "Select your device")).tag("")
                                ForEach(session.candidates) { Text($0.name + " · " + $0.address + ($0.approvalPending ? t(" · 승인 대기", " · Approval pending") : "")).tag($0.id) }
                            }
                            Button(t("기기·승인 상태 새로 고침", "Refresh devices / approval status")) { Task { await controller.refresh() } }.disabled(controller.busy)
                            Text(t("기기 이름과 IP를 모바일 앱에서 대조하세요. 여러 후보 중 선택하지 않은 기기는 승인하지 않습니다. 관리자 API가 연결되어 있으면 승인 대기 기기도 조회합니다. API 없이 정책상 보이지 않는 기기는 관리자 콘솔에서 확인하세요.", "Compare the name and IP in the mobile app. Unselected candidates are never approved. The connected administrator API also discovers pending devices. Without API access, use the admin console for devices hidden by policy."))
                            if let peer = session.candidates.first(where: { $0.id == session.selectedID }) {
                                Button(t("선택한 기기 ping / 경로 확인", "Ping / diagnose selected device")) { controller.diagnose(peer) }.disabled(controller.busy)
                                Button(t("선택한 기기 API 승인…", "Approve selected device with API…")) { approve = true }.disabled(!controller.mobileAPIAvailable || controller.busy)
                                Text(controller.diagnosticResult).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox(t("4. 실제 연결·사용 확인", "4. Verify connection and use")) {
                        VStack(alignment: .leading, spacing: 12) {
                            if let url = session.tailscaleURL { qr(url, title: t("연결 후: Mac Tailscale 주소를 Safari로 열기", "After enrollment: open the Mac Tailscale address in Safari")) }
                            Text(session.pathVerified ? t("선택한 모바일 IP에서 Tailscale 주소의 안내 페이지 접속을 확인했습니다.", "Observed a guide request to the Tailscale address from the selected mobile IP.") : t("Tailscale 주소의 모바일 접속을 기다리는 중입니다. LAN 접속은 이 확인에 포함하지 않습니다.", "Waiting for a mobile request to the Tailscale address. LAN visits do not count here."))
                            Toggle(t("직접 확인: 파일·웹·원격 서비스가 실제로 동작함", "I verified the actual file/web/remote service"), isOn: $session.serviceVerified)
                            Toggle(t("직접 확인: Exit Node 선택·해제 전후 외부 IP 비교", "I compared external IPs after selecting and clearing the Exit Node"), isOn: $session.exitVerified)
                            Text(t("서비스·Exit Node 확인은 사용자가 기록합니다. Online·ping·안내 접속만으로 성공을 표시하지 않습니다. Wi-Fi→셀룰러와 Mac 잠자기·깨우기도 각각 확인하세요.", "Service and Exit Node checks are recorded by you. Online, ping and guide access do not imply service success. Also check Wi-Fi→cellular and Mac sleep/wake."))
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    ForEach(Array(session.guide.sections.enumerated()), id: \.offset) { _, section in
                        GroupBox(section.0) { Text(section.1).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8) }
                    }
                    Text(t("안내 세션은 15분 후 종료됩니다. 취소·종료하면 서버와 인증키 표시가 종료됩니다. 서버는 읽기 전용이며 원격 설정이나 파일 접근을 제공하지 않습니다.", "The guide expires after 15 minutes. Closing cancels the server and key display. It is read only and cannot change settings or access files."))
                    if !session.active { Button(t("새 안내 세션 시작", "Start a new guide session")) { controller.startMobile() } }
                }.padding(4)
            }
            Text(controller.message).textSelection(.enabled)
        }.padding(20).frame(minWidth: 340, idealWidth: 700, minHeight: 500, idealHeight: 780)
        .font(.system(size: 14)).tracking(0).textRenderer(TailscaleFormTextRenderer())
        .confirmationDialog(t("선택한 본인 기기만 승인할까요?", "Approve only the selected device you own?"), isPresented: $approve) { Button(t("선택한 기기 승인", "Approve selected device")) { controller.approveMobile() } }
    }
    private func qr(_ url: URL, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let image = MobileSetupSession.qr(url) { Image(nsImage: image).interpolation(.none).resizable().frame(width: 160, height: 160).padding(12).background(.white).accessibilityLabel(title + " QR") }
            Text(url.absoluteString).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button(t("주소 복사", "Copy URL")) { copy(url.absoluteString) }
        }
    }
}
