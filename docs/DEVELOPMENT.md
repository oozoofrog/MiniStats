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
| 메뉴바·자동 실행·진단 인수 | `RetroStats/App/AppDelegate.swift`: `AppDelegate`, `StatusReadout`, `diagnostic`; `RetroStats/App/main.swift` |
| 투명 팝오버 패널 | `RetroStats/PixelUI/Popover.swift`: `TransparentPopover` |
| 디스크 경고·알림·정리 진행 상태 | `RetroStats/Storage/StorageController.swift`: `StorageController`; `Storage/CacheReport.swift`: `CacheReport`, `CleanProgress` |
| DerivedData 조회·삭제 보호 | `RetroStats/Storage/DerivedDataCleaner.swift`: `inspect`, `eligible`, `ensureIdle`, `clean` |
| 대시보드·상위 프로세스·스토리지 선택 UI | `RetroStats/Dashboard/`: `DashboardModel`, `DashboardView`, `DashboardSurfaceController` |
| 비트맵 글꼴·픽셀 컴포넌트·LCD 패널 | `RetroStats/PixelUI/`: `BitmapTextRenderer`, `PixelControls.swift`, `PixelIcons.swift`, `LCD.swift` |
| 페이지 전환 | `RetroStats/Transition/`: `PageTransition`, `TransitionContainer` |
| Swift 회귀 검사 (`--self-test`) | `Testing/SelfTest.swift`, `Storage/StorageSelfTest.swift`, `Storage/DerivedDataSelfTest.swift`, `Dashboard/DashboardSelfTest.swift`, `Transition/TransitionSelfTest.swift` |
| 타깃·프레임워크·패키징 | `RetroStats.xcodeproj/project.pbxproj`, `build.sh`, `RetroStats/Info.plist`, `RetroStats/Bridging.h`, `assets/AppIcon.png` |

소스 파일은 `RetroStats/` 폴더에 있으며 `RetroStats.xcodeproj`의 `PBXFileSystemSynchronizedRootGroup`이 자동으로 추적한다. 새 Swift 파일을 `RetroStats/`에 추가하면 빌드에 자동으로 포함된다. 빌드는 `xcodebuild`로 `arm64-apple-macos26.0`을 타깃으로 하며 AppKit, SwiftUI(자동 링크), IOKit, ServiceManagement, UserNotifications를 링크한다. 번들 식별자는 `RetroStats/Info.plist`의 `local.jay.RetroStats`다. App Sandbox는 꺼져 있으며 DerivedData 삭제에 필요하다.

## GUI와 설치 검증

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

- 메뉴바 클릭 → 대시보드 → CPU/메모리 상세 정렬 → 뒤로 → 스토리지 선택/선택 해제 → 설정을 확인한다. 실제 사용자 캐시는 삭제하지 않는다.
- `--show-dashboard`와 `--show-storage`는 시작할 화면을 지정한다. macOS 상태 메뉴가 준비되기 전 표시가 되지 않으면 메뉴바 아이콘을 클릭한다.
- `--render-dashboard <절대 출력 폴더>`는 실제 시스템 수치와 저장된 캐시 조회 결과로 밝은/어두운 모드의 다섯 화면을 PNG로 렌더링한다. 로그인 등록·알림 요청·캐시 조회·삭제는 실행하지 않는다. SwiftUI 콘텐츠 배치 검사이며, 실제 유리 효과 합성과 마우스 조작 검증을 대신하지 않는다.
- `--bench-cleanup [항목 수]`(기본 100000)는 파일 시스템을 스텁으로 대체한 채 `clean` 루프(항목별 재검사·삭제 호출·이벤트 전달)만 시간을 잰다. 정리 로직 변경 전후 비교용이며 디스크를 건드리지 않는다.
- `--diagnostics-output <절대 로그 경로>`는 프로세스 조회 수와 실패 코드를 기록하는 선택적 진단 인수다. 평소 실행에는 필요 없다.
- SourceKit-LSP가 직접 `swiftc`로 묶는 파일들의 빌드 설정을 읽지 못하면 다른 파일의 심볼을 찾지 못하는 진단이 나올 수 있다. 컴파일 판정은 `make verify` 결과를 따른다.
