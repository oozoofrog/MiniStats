# MiniStats 개발 지침

Apple Silicon / macOS 26+ 메뉴바 앱. AppKit·SwiftUI Swift 네 파일을 `swiftc`로 직접 빌드한다. 외부 패키지, Xcode 프로젝트, Swift Package는 없다.

## 작업 시작

- 요청과 관련된 파일·심볼부터 읽는다. 전체 소스나 로그를 매번 읽지 않는다.
- 코드·`build.sh`가 구현 기준이며, 제품 설명은 `README.md`, 파일 지도와 검증 절차는 `docs/DEVELOPMENT.md`를 필요할 때 읽는다.
- `git rev-parse --show-toplevel`로 저장소 경계를 확인한다. Git이 없으면 그 사실을 보고하고 파일 단위로 변경을 추적한다. 기존 변경은 보존한다.
- 사용자가 지정한 모델·추론 수준을 따른다. 기본값은 `.codex/config.toml`의 Astra High이며, 별도 페르소나·위임 워크플로는 요청된 경우에만 사용한다.

## 수정과 검증

- 환경 문제는 `make doctor`. Swift·리소스·빌드 변경 완료 시 `make verify`를 실행한다. 디버거용 앱은 `make debug`.
- Python만 변경하면 `make test-python`; 앱 연동·패키징도 바뀌면 `make verify`까지 실행한다. 문서만 수정하면 경로·명령의 정확성을 확인한다.
- Swift 계산 검사는 `main.swift`의 `selfTest()`, 저장소 검사는 `Storage.swift`의 `storageSelfTest()`, 삭제 보호 검사는 `tests/test_deriveddata.py`에 있다. 동작 변경 시 관련 회귀 검사를 유지·보강한다.
- 실제 DerivedData를 테스트 대상으로 삭제하지 않는다. 삭제 검증은 임시 디렉터리에서 한다. 8시간 기준, 사용 중 차단, 경로 재검증, 심볼릭 링크·미확인 항목 보호를 유지한다.
- 앱 실행은 알림 권한 요청·로그인 항목 등록을 일으킬 수 있다. 자동 검증에는 `--self-test`만 사용하고, UI 실행·설치·로그인 항목 검증은 요청 범위에 맞게 별도로 수행한다.
- 성공한 검증은 관련 입력이 바뀌거나 새 실패가 발생했을 때 다시 실행한다. 결과는 소스 확인, 빌드/자체 검사, GUI 실행, 설치로 구분하고 실패와 전체 로그 경로를 보고한다.

## 컨텍스트 유지

긴 작업을 넘길 때 목표, 변경 파일, 검증 명령·결과·로그, 미해결 사항, 다음 행동을 짧게 남긴다. 과거 로그나 완료된 작업 내역을 이 파일에 누적하지 않는다.
