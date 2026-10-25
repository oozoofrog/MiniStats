# RetroStats 안전한 디스크 정리 검증

## 현재 상태 — 2026-10-25

스토리지 변경을 포함한 전체 작업 트리의 앱이 메뉴바 작업 중 설치되었다. 설치 이력과 미완료 GUI 검수는 [현재 상태 문서](DISK_CLEANUP_INSTALL_PLAN.md)에 구분했다. 아래 설치·커밋·푸시 미수행 문장은 당시 구현 세션의 기록이다.

전체 작업 트리의 일반 검사는 `build/logs/verify-release-20261025-115917.8fd4A3`에서 통과했다. 외장 복사·복원 검사는 `RETROSTATS_ARCHIVE_TEST_DESTINATION`을 지정해야 실행되며 해당 일반 검사에 포함되지 않는다. 실제 원본 제거는 계속 차단한다. 과거 fixture 검증은 현재 실제 데이터 작업의 성공 근거가 아니다.

스토리지 커밋 대상만 별도 경로에 내보낸 `make verify`도 통과했다. [커밋 대상 검증 로그](../build/logs/storage-commit-verify-20261025.log). 외장 복사 opt-in 검사는 실행하지 않았다.

## 과거 구현 검증 — 2026-10-12 UTC

저장소는 `/Volumes/eyedisk/develop/oozoofrog/MiniStats`이며 저장소 지침, Xcode 타깃과 기존 담당 세션으로 RetroStats임을 확인했다. 담당 세션은 기존 자동 정리 작업 종료와 파일 충돌 없음으로 회신했다. 기존 Tailscale·아이콘 관련 23개 파일의 SHA256은 작업 전후 동일하다. 기존 미커밋 변경을 보존했으며 설치·커밋·푸시는 수행하지 않았다.

## 구현된 운영 기능

- `CleanupVolume.swift`: statfs 실제 가용 블록, 볼륨별 스냅샷과 전후 변화. important-usage/purgeable 추정을 분리하고 APFS 공유 용량을 합산하지 않는다. 다른 볼륨 후보를 메인 디스크 확보량으로 표현하지 않는다.
- `AutoCleanup.swift`: 알려진 재생성 캐시 정책, 7일 보존, 최근 루트/임시 폴더 활동 보호, 앱·빌드·업데이트·열린 파일의 경로 및 device/inode 확인. 프로세스 조회는 시간/출력 제한 및 취소를 지원하며 불완전 조회는 미확인으로 차단한다.
- descriptor 기반 nofollow 검사, 파일 목록·식별자·mtime/ctime·권한·소유자/그룹·flags·SHA256·확장 속성/resource fork·ACL 검증. symlink·hard link·특수 파일·마운트·권한 미확인은 보존한다.
- 원본 소스·인증·앱 설정·개인 데이터·시뮬레이터·사진·ebook·백업·검증 증거는 정책 범위 밖이다. DeviceSupport·DerivedData·일반 앱 캐시/로그·다운로드는 자동 정리 후보로 삼지 않는다.
- 선택 항목만 캐시 밖의 RetroStats 전용 같은 볼륨 복구 보관함으로 원자 이동한다. 이동은 공간 확보가 아니다. 원본 충돌/사본 변경 시 덮어쓰지 않고 보존한다. 미복원·미완료 기록을 자동 만료하지 않는다.
- 기록·미리보기는 home 범위의 owned/nofollow 디렉터리에 저장하고 파일·디렉터리를 fsync한다. journal 폴더를 symlink로 교체해 보호 파일을 덮어쓰는 경우를 차단한다.
- 일간·주간 예약은 미리보기만 실행한다. 이전 영구 삭제 예약은 v2에서 비활성으로 전환한다. 기본 화면에 영구 삭제나 휴지통 비우기는 없다.
- `Create Verified External Copy`: 사용자가 선택한 별도 APFS 컨테이너·물리 외장 장치로 전체 복사·내용/메타데이터 검증 후 사본과 manifest를 보존한다. IORegistry APFS volume UUID를 Foundation UUID와 교차 확인하고 container/physical-store UUID 및 IOBlockStorageDevice의 protocol·product·serial digest를 확인한다. 같은 컨테이너, 같은 디스크의 다른 파티션, 가상·내장·미확인 장치는 차단한다. serial 원문은 기록하지 않는다. topology는 manifest에 저장하고 사본 작업마다 재확인한다. 원본은 유지하며 확보 공간으로 표시하지 않는다. 원본이 존재하면 복원 사전 검사에서 차단해 추가 복사로 메인 공간을 소모하지 않는다.

## 실제 공간 확보는 미완료

`Archive & Reclaim`은 운영 UI·Controller·Engine에서 차단되어 있다. 원본 제거 프로토타입은 명시적으로 opt-in한 고유 `/tmp/archive-home-UUID` 합성 원본에서만 시험할 수 있다.

독립 검토에서 지적한 다음 사항은 기능 차단으로 접근을 막았으며 해결 완료로 취급하지 않는다.

1. leaf 검사와 unlink 사이 교체/기존 열린 FD 쓰기를 원자적으로 차단하는 보장.
2. 원본 제거 중 외장 사본의 불변성·복구 보장. 단계별/최종 전체 검증은 추가했지만 불변성을 보장하지 않는다.
3. 별도 APFS 컨테이너·물리 외장 장치 확인 정책은 `CleanupTopology.swift`로 추가했고 현재 메인/eyedisk를 읽기 전용으로 교차 확인했다. 알려진 메타데이터를 확인할 수 없는 장치는 미확인으로 차단한다. 이것만으로 1·2의 원본 제거 보장이 완성되지는 않는다.

후속 격리 회귀에서 rename 전에 열린 FD가 staging 후에도 원본에 쓸 수 있고, 검증된 외장 사본 역시 FD로 수정할 수 있음을 직접 재현했다. 일반 운영 엔진은 commit callback 전에 제거를 거부하여 변경된 원본을 보존했다. 이는 미해결 위험의 재현이며 안전 제거 성공 검사가 아니다.

플랫폼 근거를 독립적으로 확인했다. [공식 XNU lease 구현](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_subr.c)은 `com.apple.private.vfs.file-leases` entitlement를 요구하고 conflict lease를 강제 해제할 수 있다. [unlinkat 구현](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_syscalls.c)은 expected device/inode 인자를 제공하지 않는다. [Apple race 지침](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/RaceConditions.html)의 FSRef 역시 경로 기반으로 설명된다. 헤더의 F_SETLEASE, advisory lock, immutable flag, FSDeleteObject를 원본 쓰기 배제·원자 identity 제거 보장으로 사용하지 않는다. 최소 지원 macOS 26에서 이러한 보장을 입증한 primitive도 없다. 현재 GUI와 일반 Engine은 세 가지 정확한 차단 사유(기존 FD 쓰기 배제, inode 조건부 제거, 외장 사본 불변성)를 공유한다.

같은 볼륨 이동과 외장 copy-only만으로 사용자의 메인 공간 확보 목표가 완성된 것은 아니다. 운영 원본 제거를 활성화하지 말아야 한다.

## 최종 코드·빌드 검사

명령:

```sh
RETROSTATS_ARCHIVE_TEST_DESTINATION="$PWD/build/disk-cleanup-evidence/archive-external-fixture" make verify
```

후속 최종 로그: `build/logs/verify-release-20261013-005858.zqeLvF` — exit 0. Release 빌드, Swift 자체 검사, Metal/폰트 번들, 서명·arm64 검사 통과. 새 topology shared-container/same-physical-different-partition/unknown/virtual 차단, 24회 topology 불일치 재시도에서 source FD 보존, 기존 writer FD·mutable backup FD의 위험 재현 및 production gate 보존 검사를 포함한다. `005548.s5URyF`의 exit133은 새 FD 검사에서 socket의 음수 st_dev를 UInt64로 변환한 fixture 오류였다. 음수 비교 guard를 수정했으며 실패 로그를 보존했다. 이전 `002549.4cbiwq`는 topology 후속 수정 전 통과다. 마지막 `git diff --check` 통과.

격리 회귀는 선택/미선택, 검사 후 원본 변경, 마지막 source/root/recovery/restore-source 교체, symlink/hard link/권한, npm tmp 하위 변경, 전후 취소, 부분 batch 실패, 재실행 차단, 복원 충돌/사본 변경, 장기 미복원 기록을 포함한다. 실제 별도 파일시스템의 /tmp 합성 원본 → eyedisk 합성 보관함에서 복사·SHA256·nonempty ACL·xattr·mtime·gid·용량 부족·사본 변경·복원과 생산 제거 gate를 검사했다. 프로토타입의 제거 후 일부 실패, 사본 변경과 재실행 거부도 합성 데이터만으로 검사했다. 생산 Controller copy-only의 원본 유지·history·충돌 시 복사 없음도 통합 검사했다.

128MiB disposable APFS 이미지 생성은 성공했으나 hdiutil 연결은 권한 거부, diskutil 연결은 응답하지 않아 이 작업의 도우미만 중단했다. 실제 volume detach 검증은 **미확인**이다. 후속 작업에서 attach 우회/재시도를 하지 않았다. 2026-10-12 15:51 UTC fresh stat에서 archive-mount는 eyedisk와 동일 device였으며 연결 성공으로 판단하지 않았다. 보안 설정이나 운영 볼륨을 변경하지 않았다. 이전 컴파일/ACL fixture/journal 회귀 실패 로그는 보존했으며 최종 성공 근거와 구분한다.

Source SHA256과 바이너리: 이전 `build/disk-cleanup-evidence/final-source-inputs.json`, `final-binary.json`; 후속 `platform/final-source-inputs.json`, `platform/final-binary.json`. 실제 읽기 전용 topology 교차 확인: `platform/observed-topology.json`.

## 독립 검토

별도의 읽기 전용 검토 에이전트가 코드와 테스트를 검토했다. 초기 지적 사항인 캐시 내부 복구 위치, 최종 경로 검증, 미복원 기록 만료, process 취소, fixture 알림/설정 변경, ACL 반환값, 복원 충돌 전 사본 생성, journal symlink 문제를 수정했다. 후속 topology 검토에서 APFS partition UUID와 물리 장치 identity 혼동, archiveDirectory 실패 시 source FD 누수, 무효 iterator 순회 문제를 찾아 수정했다. 마지막 재검토에서 잔여 P1/P2를 찾지 못했다. 이는 운영 제거 프로토타입의 안전성이 증명됐다는 뜻이 아니다. 검토 에이전트는 실제 UI나 파일을 조작하지 않았다.

## 실제 UI

Book/jevi 조율 세션의 허용 창에서 고유 bundle ID의 synthetic fixture만 사용했다. 기본 복구 UI는 16KiB 합성 후보의 Preview → 선택 → 같은 볼륨 이동 → Restore 완료를 fresh AX와 스크린샷으로 확인했고, 파일 내용과 history restored=true를 재확인했다. 마지막 통과 빌드는 실제 scroll area, 보관 폴더 picker, copy-only 안내, `Archive & Reclaim` disabled, 같은 볼륨 선택의 거부 사유와 원본 유지·0개 이동/사본 기록을 fresh AX/스크린샷으로 확인했다. 그 뒤 fixture만 close해 exit 0과 원본 SHA256을 확인하고 GUI 슬롯을 반환했다.

증거: `build/disk-cleanup-evidence/same-volume-ui-evidence.txt`, `final-gui-evidence.json`, `gui-verified-final/`. 밝은/어두운·일반/큰 글씨·312/636pt PNG 8개는 `render-pass1/`에 있으며 이 렌더는 초기 UI 배치 확인이고 최종 실제 창 검증과 구분한다. fixture의 보존 기간 재현을 위한 주입 시각은 실제보다 90일 미래다.

후속 topology·구체적 source-removal 차단 안내를 포함한 최종 소스는 `005858.zqeLvF`로 빌드·회귀 및 독립 검토를 통과했다. 조율자의 새 2~3분 슬롯에서 고유 bundle ID `local.jay.RetroStats.CleanupTopologyFixture`를 16:05:25 UTC 실행했지만, 첫 cua.getApp 관찰이 tool wall2831.6초(약47분) 지연됐다. 정확한 창 제목과 메인/eyedisk 컨테이너 표시만 확인했으며 Preview/picker/scroll 입력은 0이다. 조율자와 지연을 공유하고 추가 입력을 중단했다. 그 창의 close만 수행했고 session47543의 exit0을 16:53:40 UTC 확인해 실제 반환했다. 원본 fixture의 16KiB/SHA256은 그대로이며 history도 만들지 않았다. 최신 수정본의 전체 실제 GUI는 **미완료**다. 이전 실제 GUI 통과를 새 표시 변경의 검증으로 대체하지 않는다. 현재 GUI 입력·점유 0이다. 증거: `platform/final-gui-delay-and-return.json`. 새 검수는 재배정과 응답 가능한 UI 도구가 있어야 한다.

## 설치 및 운영 데이터

### 2026-10-13 화면 접근 복구 후 새 검수

이전 지연을 성공 근거로 사용하지 않고 새 고유 synthetic fixture에서 실제 기능을 다시 검수했다. 15:16:45 UTC 시작, session40080 정상 close/exit0 및 15:20:33 UTC 반환 확인. Preview, 실제 세로 스크롤, 폴더 picker, 후보 선택 후 제거 버튼 비활성, 원본 유지 안내, 같은 볼륨 복사 차단, 후보 제외 후 빈 상태를 새 AX 및 fixture 창 PNG 5장으로 확인했다. 긴 경로가 줄바꿈되며 candidate toggle·button·disclosure의 label/value/disabled 상태가 AX에 제공된다. OS VoiceOver와 전체 키보드 접근성 검사는 별도로 수행하지 않았다. 합성 원본 16KiB/SHA256은 유지됐고, 실제 이동·외장 사본은 모두 0건이다. fixture 보존 기간의 now는 90일 미래로 주입되어 화면 history 날짜가 실제 관찰일과 다르다.

차단된 시도가 `Finished`로만 표시되고 이유가 접힌 항목에 들어가 있는 사용성 문제를 발견했다. `CleanupRecord.outcomeLabel`로 미완료·검증 완료 없음·일부 완료·완료를 구분하고, `confirmExternalCopy` 실패를 즉시 `Copy blocked` 안내로 표시하도록 최소 수정했다. `No items completed`는 실패가 임시 사본이나 복구 staging을 만들었을 수 있는 경우에도 파일 불변으로 오표현하지 않는다. 저장 형식을 변경하지 않았고 제거 gate는 false다. 해당 분류 및 실제 같은 볼륨 Controller 실패/원본 유지/즉시 오류 표시 회귀를 추가했다.

수정본 최종 `make verify`: `build/logs/verify-release-20261014-002449.035h4a`, exit0. 독립 재검토에서 문구 P2를 해소했고 추가 finding 없음. 기존 다른 변경 23개는 그대로다. 수정 후 source/binary 지문은 `build/disk-cleanup-evidence/gui-restored-access/final-source-inputs.json`, `final-binary.json`이다.

수정 문구의 fresh actual 재확인에는 별도 약2분 슬롯을 배정받았다. 15:28:19 UTC session48538 시작 후 exact cua.getApp 관찰이 10초 timeout 설정에도 wall593.56초 지연됐다. 조율 guard에 따라 Preview/picker 추가 입력0으로 중단하고 exact fixture만 close해 15:39:02 UTC exit0·GUI 반환을 확인했다. 수정 문구의 최종 실제 화면 검수는 **미완료**다. 추가 fixture 재시작은 하지 않았다.

새 증거: `gui-restored-access/actual-ui-result.json`, `01-preview.png`~`05-empty.png`, `ui-observations.txt`; 재확인 지연/반환은 `gui-error-final/delay-and-return.json`. 6쪽 화면 보고서는 `gui-restored-access/output/pdf/RetroStats-disk-cleanup-ui-review.pdf`이며 전체 페이지 렌더를 확인했다. 실제 화면 5장, 발견한 이전 표시 문제, 수정본 검증과 남은 actual gate를 구분한다. 보고서는 Library에 저장했고 파일에 반환된 Library identity/version을 적용했다. 원문 picker의 사용자 Documents 목록은 보고서에 포함하지 않았다.

Library 저장 확인의 byte 크기가 로컬 PDF와 달라 저장된 동일 버전을 materialize하여 확인했다. PDF 직렬화 bytes는 다르지만 6쪽의 PDFKit 렌더 PNG가 모두 로컬 검증본과 동일했다. `gui-restored-access/library-roundtrip/visual-verification.json`, `library-delivery.json`에 근거를 보존했다. 이 저장본도 Library identity/version을 갖고 있다. 최신 설치 준비 상태는 `gui-restored-access/installation-preparation.json`이며 설치=false, GUI 반환=true, 마지막 수정 문구 actual=false다.

설치하지 않았다. 현재 deploy-app.sh는 pgrep/pkill 후 설치 폴더를 교체하므로 실행하면 운영 앱 중단 조건을 위반한다. 설치 평가만 수행했으며 실행하지 않았다. 빌드 산출물은 `build/RetroStats.app`에 있고 GUI용 별도 식별자 사본은 `build/disk-cleanup-evidence/RetroStatsCleanupFixture.app`에 있다. 기존 설치 앱과 설정은 변경하지 않았다. 실제 사용자 캐시를 정리하거나 다른 앱을 종료하지 않았다. 참고 실제 정리 결과 파일 `/Volumes/eyedisk/MainDiskCleanupArchive/20261012T134954Z/정리결과.txt`는 읽기만 사용했다. 해당 결과의 36.54→41.96GiB/실측 5.42GiB와 관측 할당량 합계의 차이를 회귀 데이터에 반영했으며 이 구현의 확보 실적으로 주장하지 않는다.
