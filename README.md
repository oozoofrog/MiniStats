<p align="center">
  <img src="assets/AppIcon.png" width="96" alt="MiniStats 앱 아이콘">
</p>

# MiniStats

**메뉴바에서 Mac의 CPU·메모리를 모니터링하고, 오래된 DerivedData를 골라 정리합니다.**

Apple Silicon용 네이티브 macOS 앱입니다.

## 설치

Apple Silicon, macOS 26 이상에서 한 줄 설치:

```sh
curl -fsSL https://raw.githubusercontent.com/oozoofrog/MiniStats/main/scripts/install.sh | sh
```

기본 설치 경로는 `~/Applications/MiniStats.app`이다. 설치 스크립트가 저장소를 클론하고 빌드·자체 검사를 거쳐 앱을 복사한다. 소스에서 직접 빌드하므로 공증(notarization)은 되어 있지 않다. 첫 실행 시 Gatekeeper 경고가 나면 앱을 우클릭하고 "열기"를 선택한다.

## 주요 기능

- **대시보드:** CPU·메모리 실시간 그래프와 네트워크·스토리지·배터리 상태
- **프로세스:** CPU·메모리 상위 3개 미리보기와 상위 5개 상세 정보
- **DerivedData 정리:** 오래된 캐시를 선택해 정리
- **macOS 연동:** 로그인 시 자동 실행, 스토리지 알림, 활성 상태 보기·Finder 바로가기

macOS 26 이상에서 네이티브 Liquid Glass(`NSGlassEffectView`)를 사용합니다.

## 빌드와 실행

- 실행: Apple Silicon, macOS 26 이상, `/usr/bin/python3`
- 빌드: macOS 26 SDK 이상을 포함한 Xcode 또는 Command Line Tools

```sh
git submodule update --init --recursive
make verify
open build/MiniStats.app
```

## 라이센스

메뉴바 픽셀 폰트로 [Neo둥근모](https://github.com/neodgm/neodgm)를 사용하며, 해당 폰트는 [SIL Open Font License 1.1](https://scripts.sil.org/OFL)로 배포된다. 폰트 파일과 라이센스 전문은 빌드된 앱 번들에 함께 포함된다.

[개발 안내](docs/DEVELOPMENT.md) · [버그 제보·기능 제안](https://github.com/oozoofrog/MiniStats/issues)
