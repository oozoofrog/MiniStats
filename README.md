<p align="center">
  <img src="assets/AppIcon.png" width="96" alt="RetroStats 앱 아이콘">
</p>

# RetroStats

**메뉴바에서 Mac의 CPU·메모리를 모니터링하고, 오래된 DerivedData를 골라 정리합니다.**

Apple Silicon용 네이티브 macOS 앱입니다.

## 설치

Apple Silicon, macOS 26 이상에서 한 줄 설치:

```sh
curl -fsSL https://raw.githubusercontent.com/oozoofrog/MiniStats/main/scripts/install.sh | sh
```

기본 설치 경로는 `~/Applications/RetroStats.app`이다. 설치 스크립트가 저장소를 클론하고 빌드·자체 검사를 거쳐 앱을 복사한다. 소스에서 직접 빌드하므로 공증(notarization)은 되어 있지 않다. 첫 실행 시 Gatekeeper 경고가 나면 앱을 우클릭하고 "열기"를 선택한다.

## 주요 기능

- **메뉴바 스토리지:** CPU·메모리 픽셀 숫자 뒤를 스토리지 사용량만큼 채움. 겹치는 숫자는 투명하게 배경을 드러내고 색은 macOS 메뉴바의 밝기·선택 상태를 따름. 상시 물결 애니메이션은 사용하지 않음
- **빠른 요약과 상세 창:** 메뉴바 클릭은 SwiftUI 요약 패널을 열고 닫음. CPU·메모리·송수신·디스크 여유 공간을 바로 확인하고 누른 행의 내용만 작은 대시보드로 전환. 재클릭하면 요약으로 돌아오며 다른 메뉴 위치와 전체 패널 크기는 유지. Open Dashboard로 별도 상세 창을 열 수 있음. 상세 창은 크기에 따라 상단 탐색과 사이드바로 전환하며, 요약 패널을 닫아도 유지됨
- **상태 유지:** 크기를 바꿔도 현재 페이지·스토리지 선택·실시간 측정 유지
- **업데이트 주기:** 설정에서 0.1~3.0초를 0.1초 간격으로 조절하며, 즉시 반영하고 재실행 후 유지
- **프로세스:** CPU·메모리 상위 3개 미리보기와 상위 5개 상세 정보
- **액정 잔상:** 계기판의 숫자와 그래프가 바뀔 때 이전 표시가 은은하게 사라짐. 동작 줄이기에서는 비활성화
- **DerivedData 정리:** 오래된 캐시를 선택해 정리
- **스토리지 자동 정리:** 스토리지 화면에서 일간·주간 실행을 설정. DerivedData는 8시간, 개발 도구·앱 캐시는 7일, 앱 로그는 30일 기준으로 정리. 기본값은 비활성이며 대상 미리보기·경로 제외·실행 기록 제공
- **My Mac 접속:** iPhone·iPad의 첫 설치·로그인·VPN 허용을 짧은 영어 문구와 도트 그래픽으로 안내. 연결 확인과 기기 식별을 자동으로 처리하고, 저장한 접속 링크에서 준비된 파일·화면·웹·터미널 서비스를 재사용. 상세 Tailscale 관리는 고급 화면에 보존
- **권한 설정:** Settings의 PERMISSIONS에서 저장 공간 알림 권한 요청·상태 재확인·시스템 설정 이동. 전체 디스크 접근·앱 관리 설정 옆에 실제 앱 파일을 드래그할 수 있는 아이콘 안내 창을 표시. 설정 창 이동을 따라가며 Finder 위치 표시도 제공. 전체 디스크 접근 승인은 사용자가 시스템 설정에서 수행
- **macOS 연동:** 로그인 시 자동 실행, 스토리지 알림, 활성 상태 보기·Finder 바로가기

클래식 매킨토시에서 착안한 줄무늬 타이틀바와 불투명 패널, 픽셀 글꼴을 사용합니다. 설정에서 Ivory·Platinum·Phosphor 마감과 글자 크기를 선택할 수 있으며, 모든 마감은 macOS 밝은/어두운 모드를 따릅니다.

## 스토리지 자동 정리

Storage의 `AUTOMATIC CLEANUP`에서 정리 범주와 Daily·Weekly 주기를 선택하고 `Enable scheduled cleanup`을 켠다. 첫 정리는 설정한 주기 이후에 실행한다. RetroStats 실행 중 매분 예약을 확인하며, 앱이 종료되어 있던 동안 지난 예약은 다음 실행 후 확인한다. 별도 백그라운드 서비스는 설치하지 않는다.

`Preview Cleanup`은 삭제 없이 대상을 검사한다. `Show Full Preview`에서 전체 경로와 제외 사유를 확인할 수 있다. 미리보기 이후 `Permanently Delete`를 누르면 표시된 대상을 다시 검증하고 영구 삭제한다. `Exclude` 또는 Exclusions의 `Add…`로 보호할 경로를 지정한다. 하위 경로를 제외하면 그 경로를 포함한 상위 후보도 보존한다.

| 범주 | 범위 | 보존 조건 |
| --- | --- | --- |
| DerivedData | 기본·Xcode 사용자 지정 DerivedData의 인식된 프로젝트 캐시 | 기존 8시간 기준. 공유·미확인 항목 제외 |
| 개발 도구 캐시 | `~/.npm/_cacache`, `~/Library/Caches/pip`, `~/Library/Caches/Homebrew` | 7일 동안 변경이 없는 항목 |
| 앱 캐시 | `~/Library/Caches`의 등록된 앱 bundle ID 폴더 | 7일 동안 변경이 없는 항목 |
| 앱 로그 | `~/Library/Logs`의 등록된 앱 bundle ID 폴더 또는 설치된 앱 이름과 일치하는 폴더 | 30일 동안 변경이 없는 항목 |

캐시·로그는 모든 하위 항목의 수정 시각과 메타데이터 변경 시각을 확인한다. 루트 폴더는 유지한다. 소유 앱·개발 도구가 실행 중이면 해당 범주를 건너뛴다. 프로세스 조회가 실패하면 정리를 중단한다. 삭제 전 파일 식별자와 경로를 다시 확인하고, 심볼릭 링크·하드 링크·다른 파일시스템·읽을 수 없는 항목은 보존한다. Application Support, 앱 컨테이너, 다운로드, 휴지통, Apple 시스템 앱 캐시는 자동 정리 범위에 포함하지 않는다.

최근 20회 실행 기록은 `~/Library/Application Support/RetroStats/auto-cleanup-history.json`에 저장한다. 삭제 항목마다 기록을 갱신하며, 중단된 실행은 완료로 표시하지 않는다. 표시 용량은 할당 블록 기준의 추정치이며 APFS에서 실제로 증가하는 여유 공간과 다를 수 있다. 실행 도중 새 앱·빌드가 시작되는 경쟁 조건을 완전히 제거할 수는 없으며, 실패·취소한 항목은 일부 파일만 삭제되었을 수 있다.

대상 분류·제외·미리보기·실행 기록 흐름은 [Mole CLI](https://github.com/tw93/Mole)를 참고했다. Mole의 코드나 CLI를 포함하지 않는 네이티브 Swift 구현이다.

## 빌드와 실행

- 실행: Apple Silicon, macOS 26 이상
- 빌드: macOS 26 SDK 이상을 포함한 Xcode

```sh
make verify
open build/RetroStats.app
```

## 라이센스

대시보드와 메뉴바 계기는 직접 그린 5×7 고정 폭 글꼴 `RetroBitmapA`를 사용한다. 영문·숫자·기본 기호와 시안의 ‘한’, ‘글’은 글꼴 안에 픽셀 패턴으로 정의했고, 그 밖의 문자와 임의의 프로세스·파일 이름은 macOS 글리프를 선명한 픽셀 격자로 표시한다. macOS 알림·메뉴·대화상자는 시스템 글꼴을 따른다.

[최신 릴리스](https://github.com/oozoofrog/MiniStats/releases/latest) · [My Mac 사용 안내](docs/TAILSCALE_USER_GUIDE.md) · [개발 안내](docs/DEVELOPMENT.md) · [버그 제보·기능 제안](https://github.com/oozoofrog/MiniStats/issues)
