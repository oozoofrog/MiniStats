# RetroStats 개발 환경

## 시작

프로젝트 루트에서 다음 명령을 사용한다. macOS 26 SDK 이상을 포함한 Xcode가 설치된 Apple Silicon Mac이 필요하다.

```sh
make doctor
make verify
```

`make verify`는 환경 확인 → 릴리스 빌드 → Swift 자체 검사 → 번들·서명·arm64 확인을 실행한다. 실패한 단계에서 종료하고 원래 실패 상태를 반환한다. 전체 로그는 `build/logs/verify-release-*`에 저장하며 터미널에는 마지막 18줄과 로그 경로를 표시한다.

`RetroBitmapA.ttf`는 `scripts/generate_bitmap_font.py`의 5×7 문자표에서 만든 버전 관리 리소스다. 일반 빌드에 외부 Python 패키지는 필요 없다. 글자 패턴을 수정해 글꼴을 재생성할 때만 스크립트 머리말의 fontTools 설치·실행 명령을 사용한다.

| 명령 | 결과 |
| --- | --- |
| `make doctor` | 도구·SDK·필수 입력·Git 경계 확인. 컴파일하지 않음 |
| `make verify` | `build/RetroStats.app` 생성과 전체 검증, 로그 저장 |
| `make debug` | Debug 구성으로 `build/debug/RetroStats.app` 생성과 동일 검증 |
| `./build.sh` | 릴리스 빌드·서명·Swift 자체 검사 |
| `make run` / `make install` | 빌드 후 `~/Applications`(또는 `DIR=`)에 복사, `run`은 실행까지 |

Swift 자체 검사는 약 3초간 실제 CPU·메모리·네트워크 등을 읽는 검사도 포함한다. 따라서 순수 단위 테스트만으로 구성된 명령이 아니며 macOS 실행 환경이 필요하다. DerivedData 검사는 임시 폴더만 삭제한다. 번들 검증은 ad-hoc 서명을 확인하며 notarization이나 배포 검증을 뜻하지 않는다.

## 파일 지도

| 작업 | 먼저 볼 파일과 심볼 |
| --- | --- |
| CPU·메모리·네트워크·디스크·배터리 계산 | `RetroStats/Metrics/Metrics.swift`: `cpuLoad`, `memoryUsage`, `parseNetwork`, `networkRate`, `DiskUsage` |
| 프로세스 샘플링·순위 | `RetroStats/Metrics/Processes.swift`: `processSamples`, `rankedProcesses`, `ProcessOrder` |
| 메뉴바·자동 실행·진단 인수 | `RetroStats/App/AppDelegate.swift`: `AppDelegate`, `diagnostic`; `RetroStats/App/StatusReadout.swift`: `StatusReadout`, `StorageBitFill`, `statusReadoutImage`; `RetroStats/App/main.swift` |
| 반응형 단일 창·메뉴바 열기/닫기 | `RetroStats/Dashboard/DashboardView.swift`, `DashboardSurfaceController.swift`; `AppDelegate.openDashboard`, `toggleDashboardSize` |
| 디스크 경고·알림·정리 진행 상태 | `RetroStats/Storage/StorageController.swift`: `StorageController`; `Storage/CacheReport.swift`: `CacheReport`, `CleanProgress` |
| DerivedData 조회·삭제 보호 | `RetroStats/Storage/DerivedDataCleaner.swift`: `inspect`, `eligible`, `ensureIdle`, `clean` |
| 대시보드·상위 프로세스·스토리지 선택 UI | `RetroStats/Dashboard/`: `DashboardModel`, `DashboardView`, `DashboardSurfaceController` |
| 비트맵 글꼴·픽셀 컴포넌트·클래식 테마 | `RetroStats/PixelUI/`: `BitmapTextRenderer`, `RetroTheme.swift`, `PixelControls.swift`, `PixelIcons.swift`, `LCD.swift` |
| 페이지 전환 | `RetroStats/Transition/`: `PageTransition`, `TransitionContainer` |
| Swift 회귀 검사 (`--self-test`) | `Testing/SelfTest.swift`, `Testing/StatusReadoutSelfTest.swift`, `Storage/StorageSelfTest.swift`, `Storage/DerivedDataSelfTest.swift`, `Dashboard/DashboardSelfTest.swift`, `Transition/TransitionSelfTest.swift` |
| 타깃·프레임워크·패키징 | `RetroStats.xcodeproj/project.pbxproj`, `build.sh`, `RetroStats/Info.plist`, `RetroStats/Bridging.h`, `assets/AppIcon.png` |

소스 파일은 `RetroStats/` 폴더에 있으며 `RetroStats.xcodeproj`의 `PBXFileSystemSynchronizedRootGroup`이 자동으로 추적한다. 새 Swift 파일을 `RetroStats/`에 추가하면 빌드에 자동으로 포함된다. 빌드는 `xcodebuild`로 `arm64-apple-macos26.0`을 타깃으로 하며 AppKit, SwiftUI(자동 링크), IOKit, ServiceManagement, UserNotifications를 링크한다. 번들 식별자는 `RetroStats/Info.plist`의 `local.jay.RetroStats`다. App Sandbox는 꺼져 있으며 DerivedData 삭제에 필요하다.

## GUI와 설치 검증

`RETROSTATS_STATUS_READOUT_OUTPUT="$PWD/build/logs/status-readout-native" make verify`로 메뉴바 네이티브 렌더러의 투명 PNG, 확대 비교 이미지와 수면 애니메이션 GIF를 추가 출력할 수 있다. 0·25·62·100% 스토리지를 비교하며, 앱 GUI·로그인 등록·알림 서비스를 시작하지 않는다. 실제 메뉴바의 배경·클릭·다중 디스플레이 검증은 별도다.

앱을 직접 실행하기 전 기존 RetroStats를 메뉴에서 종료한다. 같은 번들 식별자의 앱이 실행 중이면 새 앱은 종료하므로, 실행 명령 성공만으로 새 빌드를 확인했다고 판단하지 않는다.

```sh
open build/RetroStats.app --args --show-dashboard
# 55% 스토리지 경고를 미리 보려면 종료한 뒤:
open build/RetroStats.app --args --preview-storage-warning
```

GUI 실행은 알림 권한 요청과 로그인 자동 실행 등록을 일으킬 수 있다. 경고 미리보기도 앱 실행이므로 이러한 부수 효과가 있다. 메뉴바 수치·정렬, 메뉴 갱신, 알림과 재실행 상태, 로그인 실행은 GUI에서 별도로 확인한다. 실제 캐시 삭제는 개발 환경 검증 절차에 포함하지 않는다.

디버깅은 `make debug` 후 `lldb build/debug/RetroStats.app/Contents/MacOS/RetroStats`로 시작할 수 있다. GUI를 시작하지 않고 자체 검사를 디버깅하려면 LLDB에서 `run --self-test`를 사용한다.

`make verify`/`./build.sh`는 앱을 설치하지 않는다. `make install`·`make run`은 실행 중인 RetroStats를 종료한 뒤 `DIR`(기본 `~/Applications`)의 기존 설치본을 덮어쓴다.

## 대시보드 검증

- 메뉴바 클릭 → 단일 창 → 상단 탐색 또는 사이드바의 독립 CPU/메모리 페이지 → 네트워크 → 스토리지 선택/선택 해제 → 설정을 확인한다. 실제 사용자 캐시는 삭제하지 않는다.
- 처음에는 400×660 크기로 열리며, 창 우측 상단의 확대/축소 버튼이나 창 가장자리로 크기를 바꾼다. 폭 680pt에서 상단 탐색과 사이드바가 전환된다. 같은 호스팅 뷰를 유지하므로 페이지·스토리지 선택·측정 상태가 초기화되지 않아야 한다. 메뉴바 재클릭 또는 ⌘W로 닫으면 프로세스 샘플링을 중단한다. 창을 다른 앱 뒤로 보내도 자동으로 닫히지 않는다.
- `--show-dashboard`와 `--show-storage`는 대시보드 창의 시작 화면을 지정한다.
- `--render-dashboard <절대 출력 폴더>`는 실제 시스템 수치와 저장된 캐시 조회 결과로 밝은/어두운 모드에서 360pt·400pt·840pt 폭의 여섯 화면을 PNG 36개로 렌더링한다. 로그인 등록·알림 요청·캐시 조회·삭제는 실행하지 않는다. 상세 화면은 전체 내용을 확인할 수 있도록 긴 캔버스로 출력한다. SwiftUI 콘텐츠 배치 검사이며, 실제 창 타이틀바와 마우스 조작 검증을 대신하지 않는다. 추가 `tailscale-fixtures/`에는 CLI/API/server가 비활성인 상태·큰 글씨·긴 기기 이름·영어 fixture PNG와 설치/접속 허브 HTML을 저장한다. 네이티브 폼은 화면에 띄우지 않은 NSHostingView로 캡처한다.
- `--bench-cleanup [항목 수]`(기본 100000)는 파일 시스템을 스텁으로 대체한 채 `clean` 루프(항목별 재검사·삭제 호출·이벤트 전달)만 시간을 잰다. 정리 로직 변경 전후 비교용이며 디스크를 건드리지 않는다.
- `--diagnostics-output <절대 로그 경로>`는 프로세스 조회 수와 실패 코드를 기록하는 선택적 진단 인수다. 평소 실행에는 필요 없다.
- SourceKit-LSP가 직접 `swiftc`로 묶는 파일들의 빌드 설정을 읽지 못하면 다른 파일의 심볼을 찾지 못하는 진단이 나올 수 있다. 컴파일 판정은 `make verify` 결과를 따른다.


## Tailscale 모듈

- 구현 위치는 `RetroStats/Tailscale/`. 기본 MY MAC 패널은 `DashboardView+Metrics.swift`에서 연결하고 기존 도구는 고급 화면에 보존한다. `DashboardModel`은 Network 표시 상태를 전달하며, `AppDelegate`는 사용자가 활성화했던 접속만 재시작 시 복원한다. CPU/메모리 타이머는 변경하지 않는다.
- 상태 실행기·API transport/credential store·안내 서버 factory를 테스트에서 대체한다. `--self-test`는 실제 Tailscale CLI, 클라우드 API, Keychain 자격 증명, VPN/공유/라우팅 설정을 사용하지 않는다. 자체 검사에 포함된 실제 HTTP 검사는 `127.0.0.1`에 임시 바인딩하고 닫는다.
- 대시보드 자체 검사·렌더링은 `DashboardModel(tailscale:)`에 비활성 fixture를 주입한다. 저장된 My Mac 링크의 시작·주기적 복원은 Keychain 승인을 요청하지 않으며, 읽기 거부 시 링크를 보존하고 Continue setup으로 명시적 승인을 안내한다. 기존 macOS file-based Keychain 호환 처리는 자격 증명 작업을 직렬화한 뒤 이전 interaction policy를 복원한다.
- 명시적인 UI 리뷰는 `build/RetroStats.app/Contents/MacOS/RetroStats --show-tailscale-fixture`로 한다. 이 모드는 production AppDelegate 없이 별도 개발 창을 띄우고 CLI/API/안내 서버를 시작하지 않는다. Manage/Mobile helper를 전환하고 창 폭·키보드·접근성을 확인할 수 있다. 실제 설치·네트워크 결과를 검증하는 모드가 아니다.
- 네이티브 폼은 비트맵 글꼴을 직접 그려 AppKit 입력/스크롤 레이아웃을 유지한다. 기존 대시보드와 Tailscale 패널의 bitmap shader는 유지한다.
- 정책 저장은 API 서버 검증 및 ETag 조건부 갱신을 요구한다. 기타 API 관리 기능도 선택한 tailnet과 대상만 변경하며, 기기/라우트·로컬 설정/공유는 변경 후 다시 읽는다. 인증/권한 오류가 나면 사용자에게 표시하고 로컬 기능과 구분한다.
- [사용 안내](TAILSCALE_USER_GUIDE.md), [조사와 구현 보강](TAILSCALE_RESEARCH.md), [검증 기록 및 실기기 체크리스트](TAILSCALE_VALIDATION.md).

- `MacAccessCoordinator`는 지속 허브의 주소/포트/계정 경계/Keychain token/자동 식별/서비스 준비를 관리한다. `MacAccessProbe`는 지정한 포트만 검사하며 SSH/VNC banner, SMB negotiate 응답, 웹 HTTP 응답을 서비스 인증 성공과 구분한다. `TailscaleInstaller`는 공식 HTTPS 호스트/패키지명/서명/Gatekeeper 검사를 거쳐 Installer만 연다.
- Network 또는 15분 도우미 활성 시 3초 수집, 지속 접속만 활성 시 15초 수집, 모두 비활성 시 중단한다. 지속 허브는 Tailscale 주소/저장 포트에만 바인딩하고 15분 LAN 등록 안내와 독립적으로 종료·복원된다. 설치 안내와 허브는 영어이며 `MacAccessArt`의 디자인 도트 배열/기존 RetroBitmapA를 사용한다.
- 전체 로그와 구현/fixture/오프스크린/브라우저/실기기 증거는 [TAILSCALE_VALIDATION.md](TAILSCALE_VALIDATION.md)에 구분한다. 개발 fixture는 실제 설정/설치/계정 변경을 대신하지 않는다.
