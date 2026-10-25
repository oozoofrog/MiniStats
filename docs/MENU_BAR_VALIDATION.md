# SwiftUI 메뉴바 분리 검증 — 2026-10-25

## 변경

- `RetroStatsApp`의 `MenuBarExtra(.window)`와 단일 `Window`로 요약과 상세 화면을 분리했다. UI 생성에 NSStatusItem, NSPopover, NSWindow/NSHostingView 래퍼를 사용하지 않는다. 기존 오프스크린 진단과 다른 기능의 네이티브 연동은 유지한다.
- 항상 존재하는 `MenuBarSceneLabel`이 앱 델리게이트의 상세 요청을 관찰하고 SwiftUI openWindow를 호출한다. UUID를 소비하여 초기 요청 재생을 방지한다. 시스템 앱 활성화만 NSApp.activate()를 사용한다.
- 요약 표시와 상세 프로세스 수집 수명을 분리했다. 요약 행은 해당 페이지를 선택한다. 일반 Open Dashboard는 마지막 페이지를 유지한다.
- 레트로 글꼴·팔레트·픽셀 메뉴바를 유지했다. 메뉴바 이미지는 template tint를 사용한다. 상시 물결 타이머는 제거했고 기존 수면 수학·합성 회귀 검사는 유지했다.
- 상세 창은 SwiftUI의 시스템 창 컨트롤·리사이즈를 사용한다. 제목은 안전 영역 아래에 배치하여 가림을 방지한다.

## 빌드와 자체 검사

최종 `make verify`는 종료 코드 0으로 완료했다. 빌드, 전체 Swift 자체 검사, 번들 리소스, ad-hoc 서명, arm64 확인을 포함한다.

- 전체 로그: `../build/logs/verify-release-20261025-111703.RdQRQf`
- 진입점: `--self-test`는 SwiftUI 앱과 시스템 서비스 시작 전에 종료한다.
- 신규 회귀: 요약만 표시할 때 프로세스 수집 미시작, 상세가 열린 동안 요약 닫기가 수집을 중단하지 않음, 상세 페이지 유지.
- 기존 Keychain interaction API의 deprecation 경고는 남아 있다. 이번 변경에서 새 컴파일 경고는 확인되지 않았다.
- 검증 뒤 문서와 StatusReadout.swift의 EOF 빈 줄만 정리했다. 동작 코드는 바꾸지 않았다.

초기 신규 회귀는 `setSummaryPresented` 미구현으로 실패했다(`verify-release-20261025-105939.nSTGuS`). fixture 초기화의 MainActor 격리 오류(`verify-release-20261025-110157.fhFiHG`)는 메인 스레드 초기화 경계를 명시하여 수정했다.

## 실제 UI

검증 도구가 보고한 실행 환경은 macOS 27.0.1 (26A434)이다. `build/logs/menu-summary/RetroStatsMenuFixture.app`은 최종 앱을 복사해 bundle ID를 `local.jay.RetroStats.menu-fixture`로 바꾼 검증 사본이다. `--menu-ui-fixture`에서는 알림 권한, 로그인 항목 등록, Tailscale 연결과 정리 작업을 시작하지 않는다. 운영 설치본 PID 1544는 종료하거나 교체하지 않았다. 검증 사본은 종료했다.

확인한 동작:

- 기본 시작 시 상세 창이 자동으로 열리지 않음. 요약만 열어도 상세 프로세스 수집 로그가 생성되지 않음.
- 실제 메뉴바 클릭으로 340×379 요약 패널 표시. CPU·메모리·송수신·디스크 여유 공간 표시.
- 메뉴바 재클릭과 Esc는 요약만 닫음. 상세 창은 유지됨.
- 요약 바깥의 상세 제목 표시줄 클릭은 요약만 닫음.
- CPU 행은 패널을 닫고 기존 상세 창을 CPU 페이지로 이동. 수집 generation은 유지됨.
- 일반 Open Dashboard는 Memory 페이지를 유지함. `reopen-action.log`, `reopen-result.log`에 마지막 확인을 저장함.
- 상세 창 닫기 후 프로세스 로그 증가 중단. 다시 열면 동일 페이지에서 수집 재개.
- Settings… 명령의 설정 페이지 이동.
- 상세 요청 후 앱이 active 상태로 바뀜. 시스템 제목 표시줄과 레트로 헤더가 겹치지 않음.

증거는 `../build/logs/menu-summary/`에 있다:

- `summary-final.png`: 최종 빌드의 실제 요약 패널.
- `detail-layout-final.png`: 최종 빌드의 실제 상세 창.
- `ui-layout-final.log`, `ui-final.log`, `ui-diagnostics-3.log`: 라우팅·창 표시·수집 기록.
- `renders/`: live/unavailable, light/dark, normal/large 조합의 오프스크린 PNG 8개.

자동화 제한과 복구:

- MenuBarExtra의 AXPress는 최소 SwiftUI 샘플에서도 요청 수락 후 패널을 열지 않았다. 실제 위치의 포인터 이벤트로 표시를 확인했다. `MenuProbe.swift`와 `menu-ax.swift`는 진단 파일이며 제품 소스가 아니다.
- 일부 MacPilot AXWindows 관찰은 `ax_unavailable (-25204)`로 실패했다. 현재 PID에 대한 직접 AX 조회와 정확한 창 ID 캡처로 후조건을 확인했다. 요청 수락만으로 성공을 판정하지 않았다.
- App 수준의 Scene.onChange는 상세 요청 뒤 실행되지 않았다. `ui-diagnostics-2.log`의 실패를 라벨 뷰의 명시적 관찰로 수정했고, 이후 request → opening → appeared 기록과 실제 창을 확인했다.

## 미검증 범위

macOS 26 런타임, 다중 디스플레이, Spaces·전체 화면, VoiceOver 전체 탐색은 별도다. 실제 알림 클릭, 로그인 등록, 설치·배포, 실제 정리 실행은 이번 검증에 포함하지 않았다.


## 후속 변경: 메뉴 내부 대시보드 — 2026-10-25

CPU·메모리·네트워크·스토리지 항목과 Settings는 같은 패널 내부에서 전환한다. Summary는 목록으로 돌아온다. Open Dashboard만 선택한 페이지의 별도 창을 연다. 메뉴의 선택은 로컬 SwiftUI 상태이며 메인 창의 페이지와 프로세스 수집 수명을 바꾸지 않는다.

- `make verify` 성공: `../build/logs/verify-release-20261025-113840.9USAkI`.
- 요약과 5개 페이지 × live/unavailable × light/dark × normal/large PNG 48개 생성: `../build/logs/menu-compact-renders/`. 큰 글씨 CPU·설정 화면 육안 확인.
- 설치본 PID 7613에서 실제 메뉴바 클릭 후 각 페이지와 뒤로 가기 AX 동작 확인. 각 페이지의 수치·제목이 같은 패널에 표시되고 별도 대시보드 창이 생성되지 않음을 확인. 증거: `../build/logs/menu-summary/compact-*-runtime.log`.
- `/Users/oozoofrog/Applications/RetroStats.app` 교체·실행 완료. 검증 빌드와 실행 파일 동일, 코드 서명 검증 성공. 추가 백업 없음.
- 이번 후속 검증에서는 다중 디스플레이·Spaces·VoiceOver 전체 탐색을 확인하지 않았다.


## 후속 수정: 항목 영역 안에서 펼치기 — 2026-10-25

패널 전체 페이지 전환과 Summary 버튼을 제거했다. 선택한 행 바로 아래에 작은 대시보드가 펼쳐지고 나머지 행은 유지된다. 같은 행을 다시 누르면 접힌다. 다른 행을 선택하면 이전 대시보드는 접힌다. 0.22초 이동·투명도 전환을 적용하며 동작 줄이기에서는 애니메이션을 생략한다.

- 전체 검사 성공: `../build/logs/verify-release-20261025-114055.BPBVEX`.
- 렌더링 48개: `../build/logs/menu-inline-renders/`. 큰 글씨 CPU 펼침 이미지에서 나머지 행 유지와 배치를 확인했다.
- 설치본 PID 8645에서 CPU 펼침·재클릭 접힘을 확인했다. 다른 네 항목과 명령이 유지되고 메인 창이 열리지 않았다. 증거: `../build/logs/menu-summary/inline-expanded-runtime.log`, `inline-collapsed-runtime.log`.
- 설치본 교체·실행과 실행 파일 일치·서명 검증 완료. 애니메이션 중간 프레임의 육안 검수와 동작 줄이기 실제 설정 전환은 별도로 확인하지 않았다.


## 최종 수정: 고정 영역 대시보드 — 2026-10-25

행 아래 펼침을 제거했다. 원래 요약 행을 레이아웃 기준으로 유지하고 같은 영역의 overlay에서만 대시보드로 바꾼다. 전환은 opacity와 0.96 scale을 사용하며 동작 줄이기에서는 생략한다. Settings는 별도 설정 창을 연다.

- 전체 검사: `../build/logs/verify-release-20261025-114240.kkxzUo` 성공.
- `../build/logs/menu-row-renders/`: live/unavailable, light/dark, normal/large의 모든 지표 전환 전후 PNG 크기 동일. 일반 340×379pt, 큰 글씨 340×419pt.
- 실제 설치본 CPU·Memory 선택 전후 AXWindow 및 모든 AXButton의 위치·크기 동일. `row-before.log`, `row-cpu.log`, `row-memory-current.log`에 증거 기록.
- 최초 일괄 관찰 도중 실행 PID가 9577에서 9619로 변경되어 일부 관찰이 비어 있었다. 새 PID를 확인한 뒤 Memory를 다시 검사했다. 이 실패를 좌표 검증 성공으로 포함하지 않았다.


## 권한 설정 — 2026-10-25

Settings의 PERMISSIONS에 알림 권한 상태·요청·시스템 설정 이동·재확인을 추가했다. 시작 시 자동 권한 요청을 제거했다. 사용자가 Request Permission을 눌렀을 때만 요청하며, 거부 상태는 시스템 설정에서 변경한다. 앱이 다시 active가 되면 알림 상태를 갱신한다. 파일 접근 거부 안내에는 전체 디스크 접근 설정과 실행 중인 Bundle 위치의 Finder 표시를 제공한다. 전체 디스크 접근 승인 상태는 추측하지 않는다. 기존 로그인 등록은 유지한다.

- 최종 `make verify`: `../build/logs/verify-release-20261025-114524.0bGe9J`, 종료 0. 알림 미확인·미요청·거부·허용·알림 비활성 상태 매핑 검사 포함.
- `../build/logs/permissions-renders/light-minimum-settings.png`에서 360pt 설정의 버튼·설명 배치 확인.
- 설치본 PID 10498의 실제 설정에서 PERMISSIONS와 Allowed 상태, 요청·설정·재확인 버튼 표시 확인. Refresh 후 Allowed 상태 재확인. `permissions-runtime.log`, `permissions-refreshed-runtime.log`에 기록.
- 검증 빌드 설치·실행, 실행 파일 일치, 서명 검증 완료.
- 이미 허용된 계정에서 확인했으므로 최초 macOS 권한 요청·거부/승인 전환은 실제로 수행하지 않았다. 시스템 설정·Finder 버튼의 목적지 실행과 전체 디스크 접근 승인은 이번 검증에서 수행하지 않았다.
- 플랫폼 근거: https://developer.apple.com/documentation/usernotifications/unusernotificationcenter 및 https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox


## 권한 버튼 실제 목적지 확인 — 2026-10-25

설치본 PID 10498의 Settings 버튼을 AXPress로 실행하고 목적지 앱의 새 AX 트리·스크린샷으로 확인했다. 시스템 설정 PID 9391, Finder PID 686. macOS 27.0.1 (26A434).

- Notification Settings…: 시스템 설정의 RetroStats 전용 알림 화면. 제목 RetroStats, 알림 허용 토글과 알림 스타일을 확인했다.
- Full Disk Access…: 시스템 설정의 전체 디스크 접근 권한 화면과 앱 목록·추가 버튼을 확인했다.
- Show RetroStats in Finder: Finder가 `/Users/oozoofrog/Applications/`를 열고 `/Users/oozoofrog/Applications/RetroStats.app/`을 선택했다. Finder selection의 POSIX 경로를 별도로 조회했다.
- 세 버튼 모두 목적지가 일치했다. 권한 토글·앱 등록·승인 상태는 변경하지 않았다.
- 증거: `../build/logs/menu-summary/notification-settings-verified.png`, `full-disk-settings-verified.png`, `finder-app-verified.png`. 실행 및 AX 기록: `permission-*-action.log`, `notification-settings-destination.log`, `full-disk-settings-destination.log`.


## 드래그 권한 안내 창 — 2026-10-25

Full Disk Access 버튼은 SwiftUI Window로 작은 앱 아이콘 창을 열고 시스템 설정의 전체 디스크 접근 항목을 연다. SwiftUI onDrag는 실행 중인 Bundle.main.bundleURL을 NSURL NSItemProvider로 제공한다. Finder를 열지 않는다. 공개 WindowServer bounds와 AppKit 위치 API로 설정 창 옆에 배치한다. 설정 창이 이동하면 따라가며 다른 앱이 전경이면 숨긴다. 아이콘의 메뉴에서 닫을 수 있다. 사용자 승인을 자동 수행하지 않는다.

- `make verify` 성공: `../build/logs/verify-release-20261025-115059.WsbJEf`. 최초 CFDictionary 조건부 변환 컴파일 오류는 Swift dictionary 브리징으로 수정했다.
- 설치·실행, 실행 파일 일치·서명 검증 완료. 실제 PID 12692의 아이콘 창 확인. SwiftUI title bar 포함 88×120pt.
- 설정 창을 (1164,62)에서 (1000,80)으로 옮겼을 때 안내 창이 왼쪽 (1066,407)에서 오른쪽 (1750,425)으로 이동. 설정 창은 원래 위치로 복구했다.
- 다른 앱 전경 전환 시 안내 창 onScreen=false, RetroStats/설정 활성화 후 다시 표시 확인.
- provider 진단에서 public.file-url과 `/Users/oozoofrog/Applications/RetroStats.app` URL 일치 확인. 최초 진단의 메인 스레드 세마포어 대기는 시간 초과하여 RunLoop로 수정했다. 진단 파일·로그는 `../build/logs/menu-summary/drag-provider-check.*`.
- MacPilot cross-window drag는 out_of_bounds로 차단됐다. 실제 시스템 목록으로 드롭·등록·인증 완료는 미검증이며 성공으로 간주하지 않는다. 동작 추적 중 PID 변경 및 숨겨진 창 AX 관찰 실패는 fresh PID/foreground 관찰로 분리했다.
- 실제 안내 화면: `../build/logs/menu-summary/permission-drag-guide.png`.
- 참고: https://findanyfile.app/enable_full_disk_access.html , https://macgoblin.com/guide/getting-started/permissions/ .


## 앱 관리 등록 안내 — 2026-10-25

Settings → PERMISSIONS에 App Management 버튼을 추가했다. 전체 디스크 접근과 같은 SwiftUI 아이콘 창을 재사용하며 선택한 권한의 URL·툴팁·접근성 안내·우클릭 메뉴를 갱신한다. 실행 중인 앱 파일 URL을 드래그한다.

- `make verify` 성공: `../build/logs/verify-release-20261025-115414.e3ixyB`. 권한별 URL 분리 회귀 포함.
- 설치본 실행 파일 일치·서명 검사 성공.
- PID 13705의 App Management 버튼 클릭 후 시스템 설정 제목 ‘앱 관리’, 아이콘 창 표시와 ‘App Management application list’ 접근성 안내 확인. `../build/logs/menu-summary/appmanagement-action.log`, `appmanagement-destination.log`, `appmanagement-verified.png`.
- Full Disk Access로 변경 시 아이콘 안내 문구는 갱신됐다. 이후 실행 PID가 13760으로 바뀌어 설정 목적지 왕복 검증은 완료하지 못했다. 앱 관리 목록으로 실제 드롭·승인도 미검증이다.
- 현재 build.sh는 codesign --sign -를 사용한다. 설치본 designated requirement가 cdhash로 구성된 것을 확인했다. 재빌드 후 반복 권한 요구는 이 ad-hoc 서명과 관련될 가능성이 높지만, 이번 변경은 서명 정책을 바꾸지 않았다. 근거: https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements


## 업데이트 서명 식별 고정 — 2026-10-25

ad-hoc 서명을 oozoofrog 팀의 Apple Development 인증서로 변경했다. build.sh와 Xcode Debug/Release 모두 같은 인증서를 지정한다. 인증서 부재 시 실패한다. 설치 전 팀·앱 ID·코드 서명을 검증하며, 기존 인증서 설치본과 DR이 다르면 종료·교체 전에 실패한다.

- Release 전체 검사: Verification log: /Volumes/eyedisk/develop/oozoofrog/MiniStats/build/logs/verify-release-20261025-115734.pyow9Z
- Debug 전체 검사: Verification log: /Volumes/eyedisk/develop/oozoofrog/MiniStats/build/logs/verify-debug-20261025-115742.b22QbB
- Release/Debug 실행 파일 SHA-256은 다르지만 DR 텍스트가 동일함을 cmp로 확인. `../build/logs/signing/release-requirement.txt`, `debug-requirement.txt`.
- 기존 ad-hoc 설치본이 새 서명 검증에서 실패함을 확인. 초기 -R 인수에서 inline requirement 접두사 `=` 누락으로 검증이 실패했으며 이를 수정 후 전체 검사를 재실행했다.
- Release 설치·실행 PID 15231. 설치 후 서명 검사와 원본 실행 파일 일치 확인. `../build/logs/signing/install.log`.
- 실제 사용자 승인 후 다음 버전 업데이트에서 TCC 권한이 유지되는지 E2E는 미검증. 이번 ad-hoc → 인증서 전환은 일회성 재승인이 필요할 수 있음. 권한 DB·승인 상태는 변경하지 않았다.


## 메뉴 행에 메인 전환 엔진 적용 — 2026-10-25

메뉴의 별도 opacity/scale 전환과 0.22초 애니메이션을 제거했다. 메인 DashboardContentView와 동일한 TransitionContainer 및 model.transitionStyle.makeTransition(color:duration:)을 사용한다. 속도는 model.transitionSpeed.duration을 공유한다. 원래 요약 행은 숨긴 레이아웃 기준으로 유지하고 overlay 내부에서만 전환한 뒤 행 경계로 clip한다. 동작 줄이기와 요청 큐도 기존 컨테이너가 담당한다.

- 전체 검사 성공: Verification log: /Volumes/eyedisk/develop/oozoofrog/MiniStats/build/logs/verify-release-20261025-115917.8fd4A3
- 모든 32개 지표 렌더 변형의 패널 크기가 요약과 동일함을 확인. `../build/logs/menu-shared-transition-renders/`.
- 인증서 서명 검사·기존 설치본 DR 비교를 통과하여 설치·실행했다. `../build/logs/menu-summary/shared-transition-install.log`.
- 실제 CPU 전환 전후 패널·모든 버튼의 위치와 크기가 동일하다. `shared-transition-before.log`, `shared-transition-after.log`. 단일 클릭 후 작은 대시보드 표시도 캡처로 확인했다.
- 현재 사용자 설정 Flip/Fast에서 창 녹화: `shared-transition.mp4`. 중간 프레임의 미세 변화는 관찰했지만 전환 전체의 시각 품질 검증으로 간주하지 않는다. 후속 녹화는 첫 샘플 버퍼 실패 및 메뉴가 없는 상태의 AX 조회 실패로 완료하지 못했다. Wave/Dissolve의 실제 메뉴 녹화는 미검증이며 기존 전환 회귀 검사는 통과했다.


## 커밋 범위 독립 검증 — 2026-10-25

이번 메뉴바·권한 안내·서명 변경만 Git index에 넣고, 기존 스토리지 정리·Tailscale·아이콘 변경은 제외했다. 같은 파일의 기존 변경도 분리했다. index 전체를 별도 `/tmp/retrostats-index-check.mEVhRZ`에 내보내 `make verify`를 실행했고 빌드·Swift 자체 검사·인증서 서명·번들·arm64 검사를 통과했다. 전체 로그: `../build/logs/commit-index-verify-release-20261025-121518.PCuK7Y`. 앞선 설치본은 기존 작업 트리의 변경도 포함했으므로 이 커밋 단독 빌드와 구분한다.
