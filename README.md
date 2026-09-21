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

- **반응형 단일 화면:** 메뉴바에서 열리는 같은 창을 늘리거나 줄여 사용. 좁은 폭에서는 상단 탐색·세로 요약, 넓은 폭에서는 사이드바·가로 계기판으로 전환
- **상태 유지:** 크기를 바꿔도 현재 페이지·스토리지 선택·실시간 측정 유지
- **프로세스:** CPU·메모리 상위 3개 미리보기와 상위 5개 상세 정보
- **액정 잔상:** 계기판의 숫자와 그래프가 바뀔 때 이전 표시가 은은하게 사라짐. 동작 줄이기에서는 비활성화
- **DerivedData 정리:** 오래된 캐시를 선택해 정리
- **macOS 연동:** 로그인 시 자동 실행, 스토리지 알림, 활성 상태 보기·Finder 바로가기

클래식 매킨토시에서 착안한 줄무늬 타이틀바와 불투명 패널, 픽셀 글꼴을 사용합니다. 설정에서 Ivory·Platinum·Phosphor 마감과 글자 크기를 선택할 수 있으며, 모든 마감은 macOS 밝은/어두운 모드를 따릅니다.

## 빌드와 실행

- 실행: Apple Silicon, macOS 26 이상
- 빌드: macOS 26 SDK 이상을 포함한 Xcode

```sh
make verify
open build/RetroStats.app
```

## 라이센스

대시보드와 메뉴바 계기는 직접 그린 5×7 고정 폭 글꼴 `RetroBitmapA`를 사용한다. 영문·숫자·기본 기호와 시안의 ‘한’, ‘글’은 글꼴 안에 픽셀 패턴으로 정의했고, 그 밖의 문자와 임의의 프로세스·파일 이름은 macOS 글리프를 선명한 픽셀 격자로 표시한다. macOS 알림·메뉴·대화상자는 시스템 글꼴을 따른다.

[개발 안내](docs/DEVELOPMENT.md) · [버그 제보·기능 제안](https://github.com/oozoofrog/MiniStats/issues)
