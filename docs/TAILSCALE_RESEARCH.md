# RetroStats Tailscale 통합 조사

조사일: 2026-09-30 (KST). 초기 조사 범위: 공식 문서·공개 소스와 당시 RetroStats 코드의 정적 확인. 아래 구현 보강은 초기 조사 이후의 별도 결과이며, 실제 Tailscale 설치·인증·설정 변경 결과와 구분한다.

## 결론

기존 Tailscale 클라이언트를 제어하는 네트워크 패널을 추가하는 방식이 적합하다. 첫 구현은 Standalone 배포판을 우선 대상으로 하고, App Store 배포판도 설치 형태와 지원 명령을 확인해 지원한다. VPN 엔진·로그인·시스템 확장은 Tailscale이 담당하고, RetroStats는 상태·기기·일상 설정·진단을 제공한다. 이 선택은 조사에 따른 설계 제안이며 실제 연동 검증 결과는 아니다.

## Tailscale이 제공하는 기능

- WireGuard로 기기 사이 통신을 암호화한다. 직접 연결을 시도하고, 불가능하면 DERP 또는 peer relay를 사용한다. DERP 사용은 연결 실패와 동일하지 않다. [암호화](https://tailscale.com/docs/concepts/tailscale-encryption), [연결 유형](https://tailscale.com/docs/reference/connection-types)
- 기기에 Tailscale IP와 MagicDNS 이름을 제공한다. 기본적인 기기 연결과 인터넷 전체를 우회하는 Exit Node 사용은 구분해야 한다. [MagicDNS](https://tailscale.com/docs/features/magicdns), [Exit Node](https://tailscale.com/docs/features/exit-nodes?tab=macos)
- Subnet Router를 통해 Tailscale을 설치할 수 없는 LAN 기기에 접근할 수 있다. 라우트 광고, 관리자 승인, 접근 정책이 필요하다. [Subnet Router](https://tailscale.com/docs/features/subnet-routers?tab=macos)
- 사용자의 접근 범위는 tailnet 정책에 따라 달라진다. 로컬에 보이는 peer 목록이 전체 관리 콘솔의 기기 목록과 같다는 보장은 없고, 보이는 기기가 모든 포트에 접근 가능한 것도 아니다. [기기 가시성](https://tailscale.com/docs/concepts/device-visibility)

## RetroStats에 추가할 수 있는 기능

| 기능 | 구현 수단 | 판단 |
| --- | --- | --- |
| 연결 상태·현재 계정·tailnet·IP·경고 | `tailscale status --json` | 첫 구현에 포함 |
| 기기 목록·OS·온라인·최근 연결 경로 | status JSON의 `Peer` | 첫 구현에 포함; 접근 가능한 로컬 관점 |
| IP·MagicDNS 이름 복사, 즐겨찾기 | status + RetroStats 자체 저장 | 첫 구현에 포함 |
| 연결·연결 해제 | `tailscale up`, `tailscale down` | 첫 구현에 포함; 로그아웃과 구분 |
| Exit Node 선택·해제·LAN 접근 허용 | `tailscale set --exit-node=…`, `--exit-node-allow-lan-access=…` | 첫 구현에 포함; 지원 배포판과 권한 확인 |
| Tailscale DNS·subnet route 수용·수신 차단 | `tailscale set --accept-dns=…`, `--accept-routes=…`, `--shields-up=…` | DNS와 수신 차단 우선, route는 고급 설정 |
| 현재 설정 표시 | `tailscale get --json` | 설치 버전의 명령 지원 확인 후 사용 |
| 지연·직접/중계 연결 진단 | `tailscale ping`, `tailscale netcheck --format=json` | 요청 시 실행; 주기적인 전체 진단은 피함 |
| Tailscale 송수신 속도·경로별 트래픽 | `tailscale metrics print` 누적 바이트 차분 | 후속 단계; 값의 실제 갱신 특성 검증 필요 |
| 계정 전환 | `tailscale switch --list --json`, `tailscale switch <id>` | 후속 단계; 소스에서 alpha로 표시 |
| SSH·SMB·웹·화면 공유 바로가기 | 기기 주소 + 사용자 지정 서비스/포트 | 후속 단계; 서버와 접근 정책이 별도로 필요 |
| Taildrop 파일 전송 | `tailscale file cp`, 공식 공유/Shortcuts 동작 | 후속 단계; 자기 소유 기기 간 전송 제한 |
| 로컬 개발 서버를 tailnet에 공유 | `tailscale serve`, `serve status --json` | 후속 단계; 공개 범위를 명시 |
| 인터넷에 로컬 서버 공개 | `tailscale funnel`, `funnel status --json` | 고급 기능; 문서 충돌 및 실제 지원 확인 필요 |
| 기기 승인·라우트 승인·DNS·정책 관리 | 클라우드 관리 API | 별도 관리 기능으로 검토 |

명령과 플래그는 [공식 CLI](https://tailscale.com/docs/reference/tailscale-cli?tab=macos)를 기준으로 했다. `set`은 지정한 설정만 변경하므로 설정 토글에 적합하다. `up`의 설정 플래그를 매번 재구성하면 기존 설정과 충돌할 수 있다. `get`, `switch --list --json` 등의 지원은 설치 버전에서 탐지해야 한다. 계정 전환 alpha 표시는 [공개 소스](https://github.com/tailscale/tailscale/blob/f5f326030b8b681079c84799ba5ec097601fcaff/cmd/tailscale/cli/switch.go)에 있다.

## macOS 배포판 제약

| 항목 | Standalone | Mac App Store | 오픈소스 CLI 전용 |
| --- | --- | --- | --- |
| GUI / CLI | 둘 다 | 둘 다 | CLI만 |
| 터널 구현 | System Extension | 앱의 Network Extension | `tailscaled` / `utun` |
| Exit Node 사용 | 지원 | 지원 | 공식 비교표상 미지원 |
| Exit Node 제공 | 지원 | 지원 | 지원 |
| Tailscale SSH 서버 | 미지원 | 미지원 | 지원 |
| SSH 클라이언트 | 지원 | 일반 `ssh` 사용 | 지원 |
| Taildrop | 지원 | 지원 | 공식 비교표상 불완전 |
| 로그인 전 실행 | 미지원 | 미지원 | 가능 |

공식 권장 설치는 Standalone이다. App Store와 Standalone을 동시에 설치하지 않도록 안내한다. [배포판 비교](https://tailscale.com/docs/concepts/macos-variants)

Standalone은 설정에서 CLI launcher를 `/usr/local/bin/tailscale`에 설치할 수 있다. App Store 버전은 `/Applications/Tailscale.app/Contents/MacOS/Tailscale`을 명령 실행 파일로 사용한다. Finder에서 시작한 RetroStats는 셸 alias나 셸 PATH를 전제로 하지 않고, 설치 앱과 실행 파일을 탐색해야 한다. [macOS CLI](https://tailscale.com/docs/reference/tailscale-cli?tab=macos)

첫 설치에는 시스템 확장·VPN 구성 승인과 로그인 과정이 필요하다. 일반 앱에서 사용자 동의를 생략하는 통합으로 설계할 수 없다. macOS 15 이상에서는 시스템 설정의 Network Extensions에서 승인하며 MDM 사전 승인은 별도 관리 환경에 해당한다. [시스템 확장 승인](https://tailscale.com/docs/concepts/macos-sysext)

일부 Standalone LocalAPI 인증 정보는 admin 그룹 읽기 권한으로 제공된다. 일반 사용자 계정에서도 모든 제어가 된다고 가정하지 말고 접근 거부를 별도 상태로 처리한다. [Darwin 인증 구현](https://github.com/tailscale/tailscale/blob/f5f326030b8b681079c84799ba5ec097601fcaff/safesocket/safesocket_darwin.go)

Tailscale SSH 서버 제한은 macOS 기본 원격 로그인 서버를 Tailscale IP로 사용하는 것과 다르다. 기본 `sshd` 접근은 원격 로그인 설정과 네트워크 정책을 따로 확인하면 된다. [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh)

### Serve / Funnel 문서 충돌

macOS 배포판 비교표는 GUI 배포판의 Funnel을 미지원으로 표기한다. 그러나 Funnel 명령 문서는 App Store·Standalone에서 **포트 공유는 가능하며 파일·디렉터리 공유는 불가**하다고 명시한다. Funnel 개요도 이 두 설명을 함께 포함하고 있어 공식 문서만으로 배포판별 지원을 확정할 수 없다.

따라서 GUI 배포판의 Funnel을 일괄 불가능 또는 검증 완료로 표시하지 않는다. 특정 설치 버전에서 capability와 실제 포트 공개·해제 동작을 확인한 후 제공한다. Serve의 파일·디렉터리 제공도 GUI 배포판에서 제한된다. [비교표](https://tailscale.com/docs/concepts/macos-variants), [Funnel 명령](https://tailscale.com/docs/reference/tailscale-cli/funnel), [Funnel 개요](https://tailscale.com/docs/features/tailscale-funnel), [Serve](https://tailscale.com/docs/features/tailscale-serve)

Funnel은 beta이며 MagicDNS·HTTPS·정책의 `funnel` node attribute가 필요하다. 공개 리스닝 포트는 443·8443·10000으로 제한되고 대역폭 제한이 있다. Serve와 Funnel은 동일 포트를 동시에 서로 다른 공개 범위로 사용할 수 없다. 로컬 서비스 선택과 공개 범위·해제 결과가 보이는 UI가 필요하다. [Funnel](https://tailscale.com/docs/features/tailscale-funnel)

## 통합 방식 선택

1. **공식 CLI — 우선 선택.** Swift `Process`에서 절대 경로·인수 배열로 실행한다. 상태와 일상 설정에는 클라우드 API 키가 필요하지 않다. 설치 버전·배포판별 명령 지원, 오류 코드, 권한, timeout을 처리한다.
2. **LocalAPI — 후속 최적화 후보.** 로컬 상태·설정·알림 스트림을 사용할 수 있지만 macOS GUI는 localhost TCP와 인증 token, CLI 전용은 Unix socket 등을 사용한다. `/var/run/tailscaled.socket` 하나로 모든 배포판을 지원하는 설계는 맞지 않는다. API 안정성이 메서드마다 다르고 `WatchIPNBus`는 불안정 API로 명시된다. [LocalAPI 클라이언트](https://github.com/tailscale/tailscale/blob/f5f326030b8b681079c84799ba5ec097601fcaff/client/local/local.go), [macOS 연결 구현](https://github.com/tailscale/tailscale/blob/f5f326030b8b681079c84799ba5ec097601fcaff/safesocket/safesocket_darwin.go)
3. **Shortcuts — 사용자 자동화 연계.** 연결, DNS, Exit Node, 계정 전환, 기기 검색·ping·파일 전송 동작이 공식 제공된다. 사용자 등록 단축어를 활용한 자동화는 가능하다. 다른 앱의 App Intent를 RetroStats에서 임의의 일반 API처럼 호출할 수 있다고 가정하지 않는다. [공식 Shortcuts](https://tailscale.com/docs/features/mac-ios-shortcuts)
4. **클라우드 API — tailnet 관리용.** 기기·정책 등 관리 작업에 사용한다. API access token 발급은 관리 역할이 필요하고 만료는 1~90일이다. 세밀한 권한에는 trust credentials 등을 검토한다. 로컬 터널 연결 전환은 CLI/LocalAPI에서 담당하게 한다. [API](https://tailscale.com/docs/reference/tailscale-api), [API 명세](https://tailscale.com/api), [Trust credentials](https://tailscale.com/docs/reference/trust-credentials)
5. **`tsnet` 내장 — 이번 목적에는 부적합.** Go 라이브러리로 앱 자체를 독립 Tailscale node로 연결할 수 있다. 기존 Mac 클라이언트 설정을 편하게 제어하려는 목적과는 다르고, 별도 네트워크 정체성·인증·런타임 의존성을 추가한다. [tsnet](https://tailscale.com/docs/features/tsnet), [앱별 node 정체성](https://tailscale.com/docs/concepts/tailscale-identity)

사용자 위임용 OAuth apps도 존재하지만 현재 alpha이며 앱과 승인 사용자가 같은 tailnet이어야 한다. 일반 소비자 앱에서 여러 고객의 tailnet에 통용되는 로그인 버튼으로 바로 사용할 수 있는 모델은 아니다. [OAuth apps](https://tailscale.com/docs/features/oauth-apps)

## 트래픽과 상태 표시의 의미

- RetroStats의 `Metrics.swift:116`은 활성 `en*`만 집계한다. 터널 트래픽을 물리 인터페이스 합계에 추가하면 중복 집계할 수 있다. 현재 Network 페이지의 전체 송수신 지표와 별도로 Tailscale 지표를 배치한다.
- `tailscale metrics print`의 `tailscaled_inbound_bytes_total` / `tailscaled_outbound_bytes_total`은 누적 카운터다. 시간 차분으로 B/s를 계산하고 `path`별 값도 합산·분리할 수 있다. client metrics는 v1.78.0 이상이다. 실제 설치판의 카운터 노출·갱신 간격을 확인한다. [Client metrics](https://tailscale.com/docs/reference/tailscale-client-metrics)
- status의 peer `RxBytes` / `TxBytes`로 로컬 Mac과 특정 peer 사이의 통신량을 표시할 수 있다. 원격 기기의 전체 인터넷 트래픽을 뜻하지 않는다. `Online`은 control plane 연결 상태이며 서비스 접근 성공을 뜻하지 않는다. `Relay`는 DERP 지역이고 현재 활성 경로를 단독으로 확정하지 않는다. `CurAddr`, `PeerRelay`, 활동 상태와 필요 시 ping 결과를 함께 사용한다. [상태 구조](https://github.com/tailscale/tailscale/blob/f5f326030b8b681079c84799ba5ec097601fcaff/ipn/ipnstate/ipnstate.go)
- `ping` 성공도 SSH·SMB·HTTP의 정책·인증·서비스 실행까지 검증한 결과는 아니다. 서비스 바로가기는 별도 서비스 접속 결과를 구분한다.
- Exit Node 제공에는 광고와 관리자 승인·사용자 접근 허용이 필요하다. macOS Exit Node는 userspace routing을 사용하며 sleep 중 가용성을 유지할 수 없다. 장애 시 무조건 Exit Node를 해제하는 자동 복구는 트래픽 경로를 바꾸므로 기본 동작으로 두지 않는다. [Exit Node](https://tailscale.com/docs/features/exit-nodes?tab=macos)
- Taildrop은 현재 alpha이고 본인 소유 기기 간 전송이며 다른 사용자 소유 기기와 tagged node는 대상이 아니다. [Taildrop](https://tailscale.com/docs/features/taildrop?tab=macos)

## 제안하는 구현 순서

### 1단계: 일상 사용

Network 페이지에 Tailscale 구역을 추가한다. 설치/CLI 탐지, 미로그인·기기 승인 대기·연결 중·연결 해제·연결됨·제어 불가 상태, 현재 IP·tailnet·health, 기기 목록·주소 복사, 연결 토글, Exit Node 선택·해제·LAN 허용, DNS·수신 차단을 제공한다. 미설치 시 공식 설치로, 미로그인 시 Tailscale 인증으로 연결한다. 픽셀 UI와 기존 물리 네트워크 지표는 유지한다.

### 2단계: 진단과 빠른 접근

기기 즐겨찾기, 사용자 지정 SSH·SMB·웹·화면 공유 단축 연결, 요청 시 ping/netcheck, Tailscale 전용 트래픽, 계정 전환을 추가한다. 온라인과 실제 서비스 접근 결과를 구분한다.

### 3단계: 고급 기능

Taildrop, Serve/Funnel, 이 Mac의 Exit Node/Subnet Router 제공, 관리 API를 검토한다. 배포판·버전·권한·공개 범위별 capability를 먼저 확인한다. tailnet 전체 DNS·접근 정책 변경은 로컬 DNS 수용 토글과 별도 기능이다.

구현 시 상태 수집과 명령 실행을 기존 0.1~3초 CPU/메모리 타이머에서 분리한다. CLI 상태 수집은 화면 활성 시 2~5초 간격을 초기 제안으로 두고 설정 변경·wake·재활성화 때 갱신한다. 비활성 화면은 감속한다. 이 간격은 성능 측정 결과가 아니다. 명령은 비동기·동시 실행 제한·timeout·출력 상한을 적용하고 stdout/stderr를 병행 소비한다. 변경 후에는 상태를 다시 읽어 반영을 확인한다. 오래된 비동기 결과가 계정 전환 이후 상태를 덮지 않도록 한다.

## 현재 확인과 후속 검증

현재 Git 작업 트리는 조사 시작 시 깨끗했다. App Sandbox는 Debug/Release 모두 꺼져 있어 외부 CLI 통합을 검토할 수 있다. 표준 `/Applications/Tailscale.app`, `~/Applications/Tailscale.app`과 현재 셸 PATH에서는 Tailscale을 찾지 못했다. 시스템 전체 미설치를 증명한 것은 아니다.

공개 소스는 `main`의 `f5f326030b8b681079c84799ba5ec097601fcaff` 스냅샷을 확인했다. 출시된 설치판과 동일한 기능 집합으로 가정하지 않는다. 원본 증거는 `/tmp/retrostats-tailscale-research-20260930/`에 임시 저장했다.

후속 구현 검증은 다음을 포함해야 한다.

- Standalone/App Store별 상태 조회·연결 토글·Exit Node 선택/해제·현재 설정 판독.
- 미설치, CLI 미설정, 미로그인, 확장 미승인, 기기 승인 대기, 접근 거부, timeout, 변경 실패 구분.
- 로그인 상태에서 disconnect와 logout 구분, 설정 일부 변경 시 나머지 보존.
- DNS·Exit Node 변경 후 실제 라우팅/이름 해석, LAN 허용 여부, sleep/wake 복구.
- 트래픽 카운터 reset·결측·활성 경로 변동 및 물리 지표 중복 방지.
- 정책 제한 peer, Direct/DERP/Peer Relay, 계정 전환 후 stale 데이터 방지.
- Serve/Funnel은 배포판별 실제 공개·해제 검증과 공개 범위 표시.
- fixture 기반 회귀 검사와 `make verify`; GUI·실제 네트워크 결과는 별도 기록.

이번 조사는 문서·소스 확인까지다. Tailscale 명령 실행, 네트워크 설정 변경, GUI 동작, 설치·실기기 연동 검증 결과는 없다.


## 2026-09-30 승인 범위 구현 보강

초기 문서의 1·2·3단계는 조사 당시의 제안 순서다. 승인된 구현에는 고급 기능도 포함했으며, 단계 구분으로 제외한 기능은 없다. 새 모듈은 `RetroStats/Tailscale/`이고 Network 패널, 관리 폼, iPhone·iPad 도우미를 연결했다.

- `TailscaleTypes.swift`: 설치/receipt/launcher 탐지, 버전별 JSON 누락, capability와 설정·peer·metrics·Serve/Funnel 모델.
- `TailscaleCLI.swift`: 절대 경로와 인수 배열, 두 pipe의 병행 소비, 출력 상한·timeout·취소·종료 스트림 검사. 실행 출력이나 인수/자격 증명을 로그로 남기지 않는다.
- `TailscaleController.swift`: 화면/등록 세션 활성 시 독립적인 3초 수집 루프, wake·설정 변경 후 갱신, 중복 제어 차단, generation 및 수집 시작/종료의 계정 정체성 비교. 관리자 기기 발견은 모바일 세션에서 최대 9초마다 읽는다.
- `TailscaleAdminAPI.swift`: 선택형 API key HTTP Basic 인증, 고정 HTTPS API 호스트/redirect 거절, Keychain, 기기/라우트 승인·DNS·HuJSON 정책, 서버 검증 및 If-Match, 일회용 비-ephemeral·태그 없는 최대 10분 키. 공식 API 클라이언트의 Basic 인증과 HuJSON/ETag 구현을 추가로 대조했다.
- `MobileSetupSession.swift`: 명시적으로 연 도우미의 15분 세션, LAN/Tailscale IP별 listener, 정확한 토큰 경로의 GET만 허용, 세션·계정·주소·선택 기기 변경 시 증거 초기화, 키 반환 경합과 종료 revoke/메모리 폐기. 키와 API 자격 증명은 HTML/QR에 포함하지 않는다.
- `TailscalePanel.swift`, `TailscaleAdminView.swift`, `MobileSetupView.swift`: 현재 상태·설정, 기기/즐겨찾기/서비스 바로가기, 요청형 진단·계정 전환, Taildrop, HTTP/HTTPS/TCP/TLS 종료 Serve/Funnel과 선택 항목 해제, Exit Node/subnet 광고, 관리 변경 전후 비교, 한국어/영어 연결 안내.
- `TailscaleSelfTest.swift`: 설치·상태·설정 보존·계정 변경·metrics·CLI pipe/timeout/cancel·API 오류/충돌·선택 기기 승인·키 수명/취소 경합·안내 라우팅/종료 fixture와 loopback HTTP 검사.

확장 승인 대기는 CLI/health에 명시적인 extension approval 신호가 있을 때만 판정한다. 단순 NoState나 daemon 부재만으로 승인 미완료를 확정하지 않는다. 제어 권한 부족과 일반 오류도 구분한다. 현재 설정을 읽을 수 없는 설치 버전에서는 값의 기본값을 추정하지 않고 공식 앱 대안을 표시한다.

Serve/Funnel은 설치된 명령 지원과 실행 후 판독으로 판단한다. HTTP/TCP 공유 상태와 전체 JSON을 읽고, 선택한 항목만 수정/해제한다. 이후 다른 경로의 공개 범위, TCP 및 미확인 필드 보존을 검사한다. 현재 설치판의 실제 Funnel 제공 능력이나 실제 공개 도달은 아직 검증하지 않았다. GUI 배포판의 파일 제공/Tailscale SSH 서버 제한은 별도로 표시한다.

도우미 후보에는 로컬 status의 iOS 기기와, 같은 tailnet의 API가 연결된 경우 승인 대기 관리 기기도 포함한다. 사용자 선택 전에는 승인 요청을 보내지 않는다. 선택되지 않은 기기의 요청과 LAN 요청은 모바일 Tailscale 경로 성공으로 합치지 않는다. 서비스와 외부 IP 우회 성공은 별도의 사용자 확인 기록이다.

초기 탐지 결과는 표준 경로에 대해 재확인했다. 실제 Tailscale 설치·인증·네트워크 변경·외부 API 변경·iPhone/iPad 연결은 수행하지 않았다. fixture/빌드/네이티브 UI/실기기 결과는 [검증 기록](TAILSCALE_VALIDATION.md)에 구분하고, [사용 안내](TAILSCALE_USER_GUIDE.md)를 추가했다.

추가 공식 소스 대조: [API 인증 클라이언트](https://github.com/tailscale/tailscale/blob/main/client/tailscale/tailscale.go), [정책 검증·ETag](https://github.com/tailscale/tailscale/blob/main/client/tailscale/acl.go), [DNS](https://github.com/tailscale/tailscale/blob/main/client/tailscale/dns.go), [라우트 API](https://github.com/tailscale/tailscale/blob/main/client/tailscale/routes.go). 추가 소스는 확인 당시 main이며 초기 고정 스냅샷이나 출시판과 동일하다고 간주하지 않는다.

## 2026-09-30 기본 자동 접속과 도트 안내 반영

최신 요구에 따라 기본 제품 흐름을 **MY MAC**으로 변경했다. 기존 Tailscale 기능 전체는 고급 관리에 보존했고, 기본 접속은 Exit Node·subnet·공개 Funnel·관리 API·인증키를 설정하지 않는다. 설치 안내의 한국어/영어 선택은 최신 요청으로 대체되어 제품 안내는 영어만 사용한다. 전용 디자인 세션의 One Step 문구·RetroBitmapA·정사각 도트 배열을 반영했다. 디자인의 타이머·모의 설치/승인/QR·Tweak는 제품으로 가져오지 않았다.

- `MacAccessCoordinator`: opt-in 지속 접속 허브, 별도 Keychain token, 저장 포트·계정/노드 경계, 재시작/wake 복원, 오류 재시도, 명시적 해제·링크 재발급. 숫자 Tailscale 주소를 기본으로 생성해 모바일 DNS 수용 여부에 의존하지 않는다. 기존 계정·주소·MagicDNS 정보는 고급 화면에 보존한다.
- 15분 LAN 설정 안내와 지속 허브는 독립적이다. 안내를 닫아도 활성화한 지속 허브의 링크는 재사용한다. 허브는 정확한 Tailscale 주소에만 바인딩하며, 서비스 동작은 보이는 같은 사용자 소유의 태그 없는 iOS peer 소스 주소를 확인한 경우에만 제공한다. 불명확한 요청은 확인 대기 화면으로 들어간다. 새로운 기기 자동 승인은 없다.
- 브라우저 안내는 설치/로그인/OS 승인 자체를 관찰할 수 없다. 이 단계는 짧은 행동 안내이며 버튼 탭으로 완료 판정하지 않는다. 정상 경로의 추가 Check Connection 버튼 없이 실제 허브 GET을 재시도하고, 허브는 돌아온 기기의 경로·서비스 목록을 갱신한다. 준비된 서비스 응답은 서비스 인증 성공과 구분한다.
- `MacAccessProbe`: 지정된 SSH/VNC banner·SMB negotiate·웹 응답 검사, localhost 웹과 원격 응답 구분. 사용자가 선택한 localhost 웹만 Serve HTTP로 공유하고 실제 target/port/path/scope 및 기존 설정 보존을 판독한 뒤 바로가기를 추가한다. 파일·화면·터미널은 선택한 목적에서만 macOS 공유 설정을 열어 사용자/폴더/권한을 정하도록 한다.
- `TailscaleInstaller`: 이미 설치된 배포판을 바꾸지 않으며, 공식 패키지 인덱스/HTTPS 호스트와 trusted Tailscale Team ID 서명·Gatekeeper 판정을 검사한 패키지만 Installer로 연다. 실제 설치·로그인·시스템 권한을 대신 승인하지 않는다.

공식 [VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand)는 iOS/macOS에서 지원되며, 활성화한 Tailscale 클라이언트의 기본 재연결 정책과 사용자 지정 규칙은 다르다. 모바일 설정은 Mac이 바꾸지 않는다. 설치 원천은 [공식 안정 패키지](https://pkgs.tailscale.com/stable/), 서명 Team ID 근거는 [공식 Mac 배포 문서](https://tailscale.com/docs/integrations/mdm/mac)에서 확인했다. 패키지 다운로드/서명 실행 자체와 실기기 접속은 이번 fixture/build 결과로 대체하지 않는다.

현재 동작과 증거 경계는 [사용 안내](TAILSCALE_USER_GUIDE.md)와 [검증 기록](TAILSCALE_VALIDATION.md)에 정리한다.
