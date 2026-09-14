# MiniStats 개발 환경

## 시작

프로젝트 루트에서 다음 명령을 사용한다. Xcode 또는 Command Line Tools가 설치된 Apple Silicon Mac이 필요하다. 시스템 Python(`/usr/bin/python3`)의 표준 라이브러리만 사용하며 패키지 설치 단계는 없다.

```sh
make doctor
make verify
```

저장소를 처음 복제한 직후, 또는 폰트 submodule이 초기화되지 않았으면 아래 명령으로 채운다. 폰트 파일이 없으면 `build.sh`가 종료된다.

```sh
git submodule update --init --recursive
```

`make verify`는 환경 확인 → 릴리스 빌드 → Swift 자체 검사 → Python 회귀 검사 → 번들·서명·arm64 확인을 실행한다. 실패한 단계에서 종료하고 원래 실패 상태를 반환한다. 전체 로그는 `build/logs/verify-release-*`에 저장하며 터미널에는 마지막 18줄과 로그 경로를 표시한다.

| 명령 | 결과 |
| --- | --- |
| `make doctor` | 도구·SDK·필수 입력·Git 경계 확인. 컴파일하지 않음 |
| `make verify` | `build/MiniStats.app` 생성과 전체 검증, 로그 저장 |
| `make debug` | `-Onone -g`로 `build/debug/MiniStats.app` 생성과 동일 검증 |
| `make test-python` | 임시 폴더에서 정리 도구 회귀 검사 |
| `./build.sh` | 기존 릴리스 빌드·서명·Swift/Python 검사 |

Swift 자체 검사는 약 3초간 실제 CPU·메모리·네트워크 등을 읽는 검사도 포함한다. 따라서 순수 단위 테스트만으로 구성된 명령이 아니며 macOS 실행 환경이 필요하다. Python 검사는 임시 파일만 삭제한다. 번들 검증은 ad-hoc 서명을 확인하며 notarization이나 배포 검증을 뜻하지 않는다.

## 파일 지도

| 작업 | 먼저 볼 파일과 심볼 |
| --- | --- |
| CPU·메모리·네트워크 계산, 프로세스 순위 | `main.swift`: `cpuLoad`, `memoryUsage`, `topCPU`, `parseNetwork`, `networkRate` |
| 메뉴바·팝오버·자동 실행 | `main.swift`: `AppDelegate`, `StatusReadout` |
| 디스크 경고·알림·정리 확인·Python 실행 | `Storage.swift`: `DiskUsage`, `CacheReport`, `StorageController` |
| DerivedData 조회·삭제 보호 | `deriveddata.py`: `inspect`, `eligible`, `ensure_idle`, `clean`, `main` |
| 대시보드·상위 프로세스·스토리지 선택 UI | `Dashboard.swift`: `DashboardModel`, `DashboardView`, `DashboardSurfaceController` |
| Swift 회귀 검사 | `main.swift`: `selfTest`; `Storage.swift`: `storageSelfTest`; `Dashboard.swift`: `dashboardSelfTest` |
| 삭제·보존·동시 작업 회귀 검사 | `tests/test_deriveddata.py` |
| 타깃·프레임워크·패키징 | `build.sh`, `Info.plist`, `Bridging.h`, `assets/AppIcon.png` |

새 Swift 파일을 추가하면 `build.sh`의 컴파일 입력에도 추가한다. 현재 빌드는 `arm64-apple-macos13.0`이며 AppKit, SwiftUI(자동 링크), IOKit, ServiceManagement, UserNotifications를 링크한다. 번들 식별자는 `Info.plist`의 `local.jay.MiniStats`다. 이름에 사용자 문자열이 있어도 단순 환경 정리 과정에서 변경하지 않는다. 기존 알림·로그인 항목과 연결될 수 있다.

## GUI와 설치 검증

앱을 직접 실행하기 전 기존 MiniStats를 메뉴에서 종료한다. 같은 번들 식별자의 앱이 실행 중이면 새 앱은 종료하므로, 실행 명령 성공만으로 새 빌드를 확인했다고 판단하지 않는다.

```sh
open build/MiniStats.app --args --show-dashboard
# 55% 스토리지 경고를 미리 보려면 종료한 뒤:
open build/MiniStats.app --args --preview-storage-warning
```

GUI 실행은 알림 권한 요청과 로그인 자동 실행 등록을 일으킬 수 있다. 경고 미리보기도 앱 실행이므로 이러한 부수 효과가 있다. 메뉴바 수치·정렬, 메뉴 갱신, 알림과 재실행 상태, 로그인 실행은 GUI에서 별도로 확인한다. 실제 캐시 삭제는 개발 환경 검증 절차에 포함하지 않는다.

디버깅은 `make debug` 후 `lldb build/debug/MiniStats.app/Contents/MacOS/MiniStats`로 시작할 수 있다. GUI를 시작하지 않고 자체 검사를 디버깅하려면 LLDB에서 `run --self-test`를 사용한다.

수동 설치 대상은 사용자가 선택한다(예: `~/Applications/MiniStats.app`). 빌드 명령은 앱을 설치하거나 기존 설치본을 덮어쓰지 않는다.

## Astra에 전달할 컨텍스트

프로젝트 기본값은 `.codex/config.toml`의 `gpt-6-astra` / `high`다. 이는 이 프로젝트에서 적용하는 개발 기본값이며 Astra 자체의 기본 추론 수준이라는 뜻은 아니다. 사용자가 작업에서 명시적으로 고른 모델·수준이 우선한다. 현재 작업의 모델이 설정 파일 편집으로 바뀌었다고 추정하지 않는다.

Codex는 신뢰된 프로젝트의 `.codex/config.toml`을 로드한다. 새 작업의 입력창 모델·추론 선택도 확인한다. 일반 ChatGPT Chat이나 웹 Work의 모델 선택을 이 파일로 변경할 수는 없다. 로컬 macOS 빌드는 로컬 개발 작업에서 실행하며, 다른 환경에 검토를 맡길 때는 필요한 파일과 검증 로그를 명시적으로 전달한다.

항상 읽는 지침은 `AGENTS.md`에만 짧게 둔다. 상세 설명은 이 문서와 README를 필요한 시점에 읽고, 로그·빌드 산출물·전체 과거 작업 내용을 시작 지침에 붙이지 않는다. 전역 메모리·스킬·MCP 설정은 이 프로젝트 설정의 범위가 아니다.

작업 요청 예시:

```text
MiniStats의 [바꾸려는 동작]을 수정해 주세요.
현재: [관찰한 동작과 재현 방법]
완료 조건: [사용자가 확인할 결과]
관련 파일: [알고 있으면 경로/심볼]
AGENTS.md를 따르고 관련 검증을 실행해 주세요.
빌드/자체 검사 결과와 GUI에서 확인한 결과를 구분해 보고해 주세요.
```

작업을 넘길 때는 목표, 바꾼 파일, 통과/실패한 검증과 로그 경로, 아직 확인하지 못한 점, 바로 다음 행동을 남긴다. 원본 로그는 필요한 부분만 읽는다.

Git 저장소가 없는 폴더에서도 빌드·검증·루트의 프로젝트 지침을 사용할 수 있다. Git diff, 커밋, worktree는 Git 저장소가 있어야 한다. Git을 도입할 때는 기존 원격/이력 유무를 먼저 확인한다.

설정 근거: [프로젝트 설정과 우선순위](https://learn.chatgpt.com/docs/config-file/config-basic), [AGENTS.md 탐색 규칙](https://learn.chatgpt.com/docs/agent-configuration/agents-md), [모델과 추론 수준 선택](https://learn.chatgpt.com/docs/models). 모델 접근 가능 여부와 실제 설정 채택은 사용하는 클라이언트·계정에서 확인해야 한다.

## 대시보드 검증

- 메뉴바 클릭 → 대시보드 → CPU/메모리 상세 정렬 → 뒤로 → 스토리지 선택/선택 해제 → 설정을 확인한다. 실제 사용자 캐시는 삭제하지 않는다.
- `--show-dashboard`와 `--show-storage`는 시작할 화면을 지정한다. macOS 상태 메뉴가 준비되기 전 표시가 되지 않으면 메뉴바 아이콘을 클릭한다.
- `--render-dashboard <절대 출력 폴더>`는 실제 시스템 수치와 저장된 캐시 조회 결과로 밝은/어두운 모드의 다섯 화면을 PNG로 렌더링한다. 로그인 등록·알림 요청·캐시 조회·삭제는 실행하지 않는다. SwiftUI 콘텐츠 배치 검사이며, 실제 유리 효과 합성과 마우스 조작 검증을 대신하지 않는다.
- `--diagnostics-output <절대 로그 경로>`는 프로세스 조회 수와 실패 코드를 기록하는 선택적 진단 인수다. 평소 실행에는 필요 없다.
- SourceKit-LSP가 직접 `swiftc`로 묶는 파일들의 빌드 설정을 읽지 못하면 다른 파일의 심볼을 찾지 못하는 진단이 나올 수 있다. 컴파일 판정은 세 파일을 함께 빌드하는 `make verify` 결과를 따른다.
- 정리 도구의 `--only-path PATH`는 기본/명시된 조회 루트에서 발견된 정리 후보를 좁히는 허용 목록이다. `--clean`과 함께 반복해서 전달할 수 있으며, 새 삭제 루트를 추가하지 않는다. 선택 중 하나라도 후보와 일치하지 않으면 삭제를 시작하지 않는다.
