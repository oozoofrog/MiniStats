# RetroStats 디스크 진단·복구 기능 상태

## 지원 범위

현재 후보는 안전한 진단·복구 기능을 제공한다. 실제 가용 공간과 purgeable 추정, APFS 공유 컨테이너를 구분하고 알려진 재생성 캐시 중 사용 중/최근 변경/권한 미확인 항목은 제외한다. 사용자가 선택한 후보만 같은 볼륨의 복구 보관함으로 이동하거나 별도 물리 외장 APFS에 검증된 사본을 만든다. 취소·부분 실패·재실행·충돌을 기록하며 복원은 덮어쓰지 않는다. 이동과 사본은 메인 디스크 확보량으로 표시하지 않는다.

원본 제거와 휴지통 비우기는 지원하지 않는다. `Archive & Reclaim`은 숨기지 않고 비활성과 구체적인 사유를 표시한다. 현재 공개 OS/API로 기존 FD 쓰기를 전체 제거 구간에서 배제하거나 inspected inode를 조건부로 삭제할 근거가 없고, 사본 전체 재검사도 불변성을 만들지 않는다. RetroStats가 생성한 journal·manifest·복구 파일 역시 같은 사용자 권한의 동시 접근을 배제할 수 없으며 복구·검증 자료라 제거 후보로 삼지 않는다. 앱이 직접 만든 파일이라는 이유로 보장 수준을 낮추지 않는다.

독립 읽기 검토에서도 추가 제거 범위를 찾지 못했다. 함수 안의 FD close와 busy 직렬화는 함수 종료·실패·crash 후의 쓰기 독점이나 inode lifetime을 입증하지 않는다. 임시 UUID journal/receipt/manifest도 생성물 ledger와 원자 identity 제거 계약이 없으며, history·preview·archive·Recovery·restore staging은 보호할 복구·검증 자료다. 따라서 현재 안전 제품 범위를 지원 한계로 명시하고 새로운 제거 기능을 덧붙이지 않는다.

## 과거 후보 — 2026-10-14

- 경로: `/Volumes/eyedisk/develop/oozoofrog/MiniStats/build/RetroStats.app`
- bundle ID: `local.jay.RetroStats`, 버전 `1.3.0`, build `8`.
- binary SHA256: `186dcf802499da3d8172efe6756011c4d5a8f08bc766dc3ce40cd4bfb78e7f7b`.
- 최종 `make verify`: `build/logs/verify-release-20261014-002449.035h4a`, exit 0.
- 소스·바이너리 지문: `build/disk-cleanup-evidence/gui-restored-access/final-source-inputs.json`, `final-binary.json`.
- 독립 검토 및 기존 다른 변경 23개 보존 확인 완료. 원본 제거 production gate는 false.

## 과거 검수와 남은 확인

2026-10-13 새 실제 기능 검수에서 Preview·scroll·picker·원본 유지·선택 후 제거 비활성·같은 볼륨 차단·빈 상태를 확인했고 session40080 exit0/15:20:33 UTC GUI 반환을 확인했다. 사용성 문제인 `Finished` 제목과 접힌 오류를 최소 수정한 뒤 빌드·회귀·독립 검토도 통과했다. 이 마지막 수정 문구의 실제 재확인은 첫 대상 관찰 wall593.56초 지연으로 guard에 따라 중단했다. Preview/picker 추가 입력 없이 session48538 exit0/15:39:02 UTC 반환 확인. 당시 최신 문구의 실제 재확인은 미완료였고 설치를 보류했다. 새 검수에는 별도 배정과 응답 가능한 UI 도구가 필요하다. Library에 저장한 6쪽 화면 보고서는 실제 기능 통과와 수정 후 남은 gate를 구분한다.

## 현재 상태 — 2026-10-25

메뉴바 UI 작업 중 스토리지·Tailscale·아이콘 변경을 포함한 전체 작업 트리로 앱을 빌드하고 `~/Applications/RetroStats.app`에 설치했다. 설치 기록은 [메뉴바 검증](MENU_BAR_VALIDATION.md)의 공유 전환 설치 항목과 `build/logs/menu-summary/shared-transition-install.log`에 있다. 위 10월 14일 지문은 과거 후보이며 현재 설치본의 지문이 아니다.

전체 작업 트리의 `make verify`는 `build/logs/verify-release-20261025-115917.8fd4A3`에서 통과했다. 일반 검사는 외장 복사 회귀를 자동 실행하지 않는다. `RETROSTATS_ARCHIVE_TEST_DESTINATION`을 지정한 별도 검사가 필요하다. 이번 문서 정리는 실제 데이터 이동·삭제·외장 복사를 수행했다는 의미가 아니다.

기존 GUI 검수 이후 변경된 결과 제목·오류 표시의 실제 재확인은 남아 있다. 앱 설치는 이 검수의 통과 근거가 아니다. 원본 제거는 Controller와 Engine에서 계속 차단한다. 지원 범위는 진단·복구 이동·검증 사본·복원이며, 메인 디스크 공간을 직접 확보하는 기능은 없다.

현재 설치 스크립트는 새 앱 서명과 기존 설치본의 designated requirement를 확인한 뒤 교체한다. 서명 정책과 실제 권한 유지의 검증 범위는 [개발 안내](DEVELOPMENT.md)를 참조한다.
