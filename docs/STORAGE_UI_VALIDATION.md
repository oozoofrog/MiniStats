# 스토리지 UI 검증

## 적용 범위

- macOS 상단 상태 아이콘은 변경하지 않았다. 기존 CPU·메모리 두 줄과 메인 디스크 사용량 배경을 유지한다.
- Storage에 연결된 볼륨 목록, 볼륨별 선택·상세, 여유/사용/전체 용량, 측정 시각, 읽기 실패 상태, Finder 접근을 추가했다.
- APFS 공유 컨테이너를 표시한다. 볼륨 용량을 합산하지 않는다. 회수 가능 추정치는 실제 여유 공간과 구분한다.
- Overview와 메뉴 팝오버에서 전체 볼륨을 확인하고 해당 볼륨의 Storage 화면으로 이동할 수 있다.
- 공간 탐색은 사용자가 시작한다. 파일 할당 크기를 읽고 하위 폴더로 이동한다. 삭제 기능과 연결하지 않는다.
- Settings는 Appearance를 먼저 배치하고, 메인 디스크 고정 표시 및 실제 갱신 주기를 안내한다.
- CPU·Memory·Network·My Mac·권한 안내·iPhone 서비스는 기존 구현을 유지한다. 시안의 예시 수치, 가짜 QR, iPhone 스토리지 기능은 추가하지 않았다.
- 정리·복원의 기존 검증·선택·확인·복구 흐름은 유지한다. 시안의 단순한 Trash 표현으로 실제 동작을 바꾸지 않았다.

## 탐색 결과의 의미

- 각 파일의 `st_blocks × 512`를 측정하며, 하드링크는 한 번만 센다.
- APFS 복제 파일은 블록을 공유할 수 있다. 합계는 고유한 디스크 사용량이나 확보 가능한 공간을 의미하지 않는다.
- 심볼릭 링크, 다른 마운트, 특수 파일, 접근 불가 항목은 제외한다.
- 기본 제한은 20초, 200,000개 항목, 깊이 64다. 제한·취소·제외 항목이 있으면 부분 측정으로 표시한다.
- 시스템의 파일 조회가 지연되면 취소 완료도 해당 호출이 끝날 때까지 기다린다.
- 볼륨 ID와 열린 디렉터리의 장치·inode를 재확인한다. 탐색은 볼륨 디스크립터 기준 `openat`과 `O_NOFOLLOW`로 하위 경로를 연다.

## 회귀 검사

모든 경로는 저장소 기준이다. 삭제되는 테스트 파일은 새로 만든 임시 디렉터리에만 있다.

| 검사 | 결과와 근거 |
|---|---|
| 볼륨 중복·메인 우선순위·읽기 실패·공유 공간·용량 경계 | `build/logs/storage-ui/volume-red.log` → `volume-green.log` |
| 메인 볼륨의 `/` 별칭 때문에 Data 마운트와 topology가 사라지는 경우 | `main-alias-red.log` → `main-alias-green.log` |
| 할당 크기·하드링크·링크 제외·제한·취소 | `explorer-red.log` → `explorer-green.log` |
| 탐색 경로 중간의 심볼릭 링크 | `intermediate-link-red.log` → `intermediate-link-green.log` |
| 큐 시작 전 취소와 볼륨 이름 변경 | `explorer-model-red.log`, `rename-red.log` → `explorer-model-green.log` |
| 출력 중인 프로세스의 취소·시간 초과 경합 | `cli-race-red.log` → `cli-race-green.log`, 100회 통과 |

## 전체 검증과 리뷰

- 최초 `make verify`: 빌드와 새 스토리지 검사는 통과했으나 기존 Tailscale CLI 취소 테스트가 실패했다. 원본 로그: `build/logs/verify-release-20261025-142724.5c3mG5`.
- 동일 바이너리 재검사는 통과했다. 종료 콜백이 취소 결과보다 먼저 성공을 전달하는 경합을 소스에서 확인했다.
- 독립 읽기 전용 리뷰에서 큐 시작 전 취소, 마운트 이름 변경, 중간 심볼릭 링크, 취소 오류 분류의 네 가지 P2를 받았다. 각각 재현 검사를 추가한 뒤 수정했다.
- 수정 후 `make verify` 통과: `build/logs/verify-release-20261025-143501.QFAueJ`.
- 메뉴의 ScrollView는 ImageRenderer에서 내용이 누락됐다. AppKit 오프스크린 캡처도 비트맵 셰이더를 정상 합성하지 못했다. 앱의 실제 스크롤은 유지하고, 렌더링 모드에서 동일한 목록 View를 같은 높이로 잘라 콘텐츠를 검증한다.
- 렌더러 변경 중 닫는 괄호 누락이 빌드에서 발견되어 수정했다. 실패 로그: `build/logs/verify-release-20261025-143833.ukRP6Q`.
- 최종 `make verify` 통과: `build/logs/verify-release-20261025-143852.H6vEyW`. Release 빌드, 전체 자체 검사, 서명·번들·아키텍처 검사를 완료했다.
- 최종 메뉴 콘텐츠: `build/storage-ui-render-complete/menu/live-light-large-storage.png`. 큰 글씨와 어두운 모드의 목록, 용량 표시, 제한된 목록 높이를 확인했다.
- 대시보드 콘텐츠: `build/storage-ui-render-final/dashboard/`. 최소 360pt와 넓은 840pt 화면에서 실제 4개 볼륨, 메인 Data 마운트, APFS 안내를 확인했다.
- `git diff --check` 통과. 상태 아이콘과 삭제·복원 핵심 파일에는 변경이 없다.

## 검증 경계

- 실제 볼륨 용량 조회, 임시 디렉터리 탐색, 컨트롤러 상태, Release 빌드, 자체 검사, 서명·번들·아키텍처 검사를 구분한다.
- `build/storage-ui-render-final/dashboard/`와 `build/storage-ui-render-complete/menu/`는 밝은/어두운 모드, 좁은/넓은 대시보드, 표준/큰 글씨 메뉴의 콘텐츠 렌더링이다. 화면상 마우스 조작이나 설치된 앱의 런타임 검증을 대체하지 않는다.
- 설치·로그인 등록·알림 권한 요청·실제 사용자 파일 정리·커밋·푸시는 하지 않았다.
