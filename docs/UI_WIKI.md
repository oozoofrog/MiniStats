# RetroStats UI 위키

메뉴바 앱의 모든 화면 요소와 컴포넌트의 이름·역할·상태를 정의한다. 트랜지션 이슈 재현이나 UI 변경 시 이 문서의 용어를 기준으로 맥락을 전달한다.

## 화면 구조 개요

메뉴바에서 여는 하나의 `NSWindow`가 기본 화면과 대시보드를 모두 담당한다. 별도 팝오버나 창 전환은 없다.

- 첫 크기: 400×660pt, 최소 크기: 360×500pt.
- 폭 680pt 미만: 상단 3열 탐색, CPU 계기판, 세로 메모리/네트워크 요약. Top Processes는 접어서 표시한다.
- 폭 680pt 이상: 좌측 사이드바, 가로 요약, CPU/메모리 프로세스 목록을 함께 표시한다.
- 우측 상단 확대/축소 버튼 또는 창 가장자리로 같은 창을 조절한다. 페이지·선택 상태는 `DashboardContentView`에 남는다.
- 창 안의 긴 페이지는 스크롤되며, 스토리지 작업 버튼은 하단에 유지된다.
- 메뉴바 재클릭이나 ⌘W로 닫는다. 다른 앱을 클릭해도 자동으로 닫히지 않는다.

## 페이지 (DashboardPage)

`overview`, `cpu`, `memory`, `network`, `storage`, `settings`. CPU와 Memory는 서로 다른 페이지이며, 공통 정렬 선택 상태를 공유하지 않는다.

`model.page` 변경은 `TransitionContainer`가 처리한다. 창 폭 변경은 페이지 전환이 아니며 같은 호스팅 뷰를 유지한다.

## Header

`RetroTitleBar`의 줄무늬와 픽셀 타이틀을 공통으로 사용한다. 창의 닫기·최소화·확대는 AppKit 기본 컨트롤이며, 우측에는 같은 창의 크기를 전환하는 버튼이 있다.

## Footer

`SYSTEM MONITOR`와 `UPDATES EVERY 3 SEC`를 표시한다. 코어·메모리 사양은 넓은 화면의 사이드바에 표시한다.

## Overview 페이지 (`overview`)

같은 데이터와 페이지를 화면 폭에 맞춰 재배치한다.

| 요소 | 구현 | 반응형 동작 |
| --- | --- | --- |
| CPU 계기판 | `RetroProcessorPanel` | 좁은 화면은 숫자와 히스토리, 넓은 화면은 코어·유휴율도 표시 |
| 메모리 요약 | `memorySummary` | 좁으면 한 줄 요약, 넓으면 사용률 바 포함 |
| 네트워크 요약 | `networkSummary` | 다운로드/업로드 표시. 클릭 시 같은 창의 `.network`로 이동 |
| 상위 프로세스 | `topProcesses` | 좁으면 DisclosureGroup 안에 세로 배치, 넓으면 CPU/Memory 목록을 나란히 표시 |
| 스토리지 | 버튼 | 볼륨 이름·여유 공간·전체 용량. 클릭 시 같은 창의 `.storage`로 이동 |
| 배터리/활성 상태 | 텍스트와 버튼 | 배터리 상태 및 Activity Monitor 실행 |

## Network 페이지 (`networkDetails`)

다운로드/업로드 전송률 계기판과 측정 기준을 표시한다. 실측하는 물리 인터페이스의 합계를 사용하며 연결 종류나 가상의 기록을 표시하지 않는다.

## CPU / Memory 페이지 (`processDetails(order:)`)

CPU와 Memory는 독립 페이지다. 공통 표시 컴포넌트에는 해당 페이지의 정렬 기준을 고정해서 전달한다. CPU 페이지는 CPU 사용률·사용자/시스템 비율·로드 평균과 CPU 상위 프로세스를, Memory 페이지는 메모리 사용량·압축·압력·스왑과 메모리 상위 프로세스를 표시한다.

| 요소 | 설명 |
| --- | --- |
| 요약 숫자 | 전체 CPU% 또는 사용 메모리 |
| 분석 텍스트 | 사용자/시스템 비율, 로드 평균, 메모리 압력/스왑 |
| 프로세스 리스트 | 상위 5개 (아이콘 + 이름 + PID + 값) |
| 안내 텍스트 | 측정 기준 설명 |
| 활성 상태 보기 버튼 | `.pixelGhost` 스타일 |

---

## Storage 페이지 (`storageDetails`)

DerivedData 정리 화면. 상태에 따라 표시가 분기된다.

### Storage 섹션 구성

| 요소 | 심볼 | 상태 조건 | 설명 |
| --- | --- | --- | --- |
| 디스크 요약 | `Text(bytes(disk.free))` + `RetroDiskMap` | `disk != nil` | 여유 공간 + 정사각 셀 디스크 맵 |
| DerivedData 헤더 | `Text("DerivedData")` | 항상 | 8시간 기준 안내 |
| PixelHourglass | `PixelHourglass` | `busy && cleaning` | 정리 중 표시 (조회 중에는 미표시) |
| 새로고침 버튼 | `PixelRefresh(animating:)` | 항상 | `busy`면 애니메이션 + 비활성화 |
| 스캔 진행 텍스트 | `Text("조회 중: \(name)")` | `busy && !cleaning` | 현재 검사 중인 경로 |
| 정리 진행 텍스트 | `Text("선택한 캐시 정리 중…")` | `busy && cleaning` | 정리 중 메시지 |
| 에러 | `Text(error)` | `lastError != nil` | 디더 표식과 기본 잉크 색, 텍스트 선택 가능 |
| 후보 리스트 | `ForEach(report.candidates)` | `report != nil && cleanProgress == nil` | 토글 + 이름 + 크기 + Finder 버튼 |
| 전체/최근조회 | `Text(...)` | `report != nil` | 전체 캐시 수 + 조회 시간 |

### Clean Progress 분기 (`cleanProgressSection`)

`storage?.cleanProgress`가 설정되면 후보 리스트 대신 표시:

| Phase | 뷰 함수 | 설명 |
| --- | --- | --- |
| `.confirming` | `cleanConfirmCard` | 삭제 확인 카드 (lcdPanel) |
| `.running` | `cleanRunningSection` | 진행 바 + 항목별 상태 (삭제중/삭제됨/유지/대기) |
| `.done` / `.cancelled` | `cleanResultSection` | 완료/취소 요약 (확보 공간, 삭제/유지/전체 수) |
| `.failed` | `cleanFailedSection` | 실패 요약 + 에러 메시지 |

### Storage Action Bar (`storageActionBar`)

`.storage` 페이지 하단에 표시. `cleanProgress.phase`에 따라 분기:

| Phase | 버튼 |
| --- | --- |
| `.confirming` | [삭제 실행] (pixelPrimary) + [취소] |
| `.running` | [정리 취소] (pixelPrimary) |
| `.done/.cancelled/.failed` | [다시 조회] (pixelPrimary) |
| 그 외 (idle) | [공용 캐시 포함 토글] + [선택한 N개 정리] (pixelPrimary) |

---

## Settings 페이지 (`settings`)

| 요소 | 설명 |
| --- | --- |
| 로그인 시 자동 실행 | `Toggle` (pixelToggle) |
| 화면 전환 효과 | `Picker` (segmented). `model.transitionStyle` 바인딩. `wave`/`fade`/`flip` |
| 전환 속도 | `Picker` (segmented). `model.transitionSpeed` 바인딩. `slow`/`normal`/`fast` → 지속 시간(1.0/0.5/0.25초) |
| 시스템 설정 승인 버튼 | `loginApproval == true`일 때 |
| 스토리지 알림 설정 | `Button` |
| DerivedData 폴더 열기 | `Button` |
| 활성 상태 보기 열기 | `Button` |
| RetroStats 종료 | `Button` (`cleaning == true`면 비활성화) |

---

## 픽셀 아이콘 컴포넌트 (`PixelIcons.swift`)

16×16 격자 기반 픽셀 아트 아이콘. LCD 테마 통일.

| 컴포넌트 | 용도 | 애니메이션 |
| --- | --- | --- |
| `PixelLED` | 실시간 표시 등 | 정지 |
| `PixelSliders` | 설정 버튼 라벨 | 정지 |
| `PixelRefresh` | 새로고침 버튼 라벨 | `animating: true` 시 chasing pixel (호를 따라 픽셀이 시계 방향 이동, 화살촉 고정). `false` 시 전체 아이콘 정지 |
| `PixelHourglass` | 정리 중 표시 | 모래시계 드레인 + 목 구간 낙하 스트림 |

## 트랜지션 컴포넌트 (`PixelTransition.swift`)

| 컴포넌트 | 역할 |
| --- | --- |
| `PageTransition` | 프로토콜. 이전·새 페이지의 마스크(`oldPageMask`/`newPageMask`)와 효과 오버레이를 `AnyView`로 반환 |
| `TransitionStyle` | `wave`/`fade`/`flip` enum. `makeTransition(color:duration:)`로 구체 트랜지션 생성. UserDefaults(`transitionStyle` 키)로 영속 |
| `TransitionSpeed` | `slow`/`normal`/`fast` enum. `duration`으로 1.0/0.5/0.25초 매핑. UserDefaults(`transitionSpeed` 키)로 영속 |
| `WaveTransition` | 파도 위프 트랜지션 (`PixelWaveMaskShape` + `PixelTransition` 밴드 오버레이) |
| `FadeTransition` | 8pt 블록 Bayer 디더 마스크로 이전/새 페이지를 상보적으로 교체. 화면에는 Dissolve로 표시 |
| `FlipTransition` | 뷰 크기에서 각 면이 정사각형인 플립 격자를 계산. 기본 400×600pt 화면은 32열×24행의 12.5×25pt 타일 768개이며, 위·아래 12.5×12.5pt 정사각형 면은 총 1,536개. 전환 시드와 타일 좌표로 시작 지연을 각각 정하고 상보적인 마스크로 두 화면을 전환 |
| `PixelTransition` | 파도 밴드 픽셀 오버레이. `TimelineView(.animation)`으로 시간 기반 렌더 |
| `PixelWaveMaskShape` | Animatable Shape. 4pt 계단형 파도 경계로 새/이전 페이지를 상보적으로 클리핑 |
| `PixelTransition.harmonics(seed:)` | 시드 기반 5중 하모닉 파도 형태 생성 (전환마다 다른 랜덤 형태) |
| `PixelTransition.waveFront(y:progress:width:harmonics:)` | 특정 y에서 파도 경계 x 계산 |

`TransitionContainer`는 `any PageTransition`을 받아 설정에서 선택한 스타일을 다음 전환에 적용한다. 진행 중인 전환은 시작할 때 선택한 효과·속도·시드를 유지한다.

### 트랜지션 상태 변수

| 변수 | 타입 | 설명 |
| --- | --- | --- |
| `progress` | `Double` | 0→1 애니메이션 진행도. `withAnimation`으로 구동 |
| `transitionStart` | `Date?` | 파도 밴드 오버레이용 시작 시각 |
| `activeTransition` | `PageTransition?` | 전환마다 뽑은 시드와 선택 당시 효과·속도를 보관 |
| `pages.visible` | `DashboardPage` | 진행 중인 효과의 고정된 새 페이지 |
| `pages.previous` | `DashboardPage?` | 전환 중 이전 페이지. `nil`이면 전환 아님 |
| `pages.requested` | `DashboardPage` | 전환 중 마지막으로 요청된 페이지 |
| `gen` | `Int` | 세대 카운터. 이전 전환의 정리 Task 무시용 |

### 트랜지션 동작 (`currentPage` 변경)

1. 이전 페이지를 저장하고 새 페이지를 `pages.visible`에 고정한다.
2. 전환마다 새 시드를 뽑아 선택한 효과에 적용한다.
3. 선택한 속도로 `progress`를 0→1 애니메이션한다.
4. 완료 후 상태를 정리하고, 그 사이 다른 페이지가 요청됐다면 마지막 요청으로 다음 전환을 시작한다.
5. 효과가 진행되는 동안 화면 내용은 입력과 접근성 포커스에서 제외된다.

전환 중 ZStack (wave/dissolve/flip 공통 마스크 경로):

- 배경: 완료 후 표시할 새 페이지 (전환 중에는 숨김)
- 위: 새 페이지, `.mask { transition.newPageMask(progress) }` — 스타일별 새 페이지 영역만 드러남
- 그 아래: 이전 페이지, `.mask { transition.oldPageMask(progress) }` — 스타일별 이전 페이지 영역만 유지
- 최상: `transition.overlay(progress, start:)` 스타일별 효과 오버레이 (파도 밴드·플립 격자선 등)

- flip: 각 타일을 정사각형인 윗면·아랫면 두 장으로 구성한다. 뷰 크기에서 면의 한 변을 약 12.5pt로 계산하고, 타일은 그 두 배 높이로 배치한다. 400×600pt 화면에는 32×24 = 768개의 12.5×25pt 타일과 1,536개의 12.5×12.5pt 면이 남김없이 들어간다. 다른 종횡비에서 남는 가장자리는 이전·새 화면을 혼합해 채운다. 이전 상단의 마스크 영역이 중심축으로 접히듯 줄고 새 하단의 마스크 영역이 펼쳐지듯 넓어진다. 전환 중에는 면의 정사각형 경계를 옅게 표시한다. 각 타일은 전환 길이의 0~55% 사이에 시작해 45%의 시간 동안 바뀌므로 먼저 시작한 타일이 먼저 완료된다. 전환 시드로 시작 순서를 고정해 프레임마다 바뀌지 않게 한다. Canvas 오버레이는 격자선만 그리며 페이지 콘텐츠를 심벌로 해석하지 않는다.

---

## 공통 UI 컴포넌트

| 컴포넌트 | 파일 | 설명 |
| --- | --- | --- |
| `LCDScreen` | LCD.swift | 현재 마감과 밝기 모드를 따르는 불투명 계기판 |
| `RetroPanelBackground` | LCD.swift | `retroPanel` 모디파이어 (사각 패널 배경) |
| `UsageBar` | LCD.swift | 사용률 바 (디스크, 정리 진행) |
| `HistoryLine` | LCD.swift | 히스토리 그래프 (CPU/메모리) |
| `PixelButtonStyle` | PixelControls.swift | `.pixel` / `.pixelPrimary` / `.pixelGhost` 버튼 스타일 |
| `PixelToggleStyle` | PixelControls.swift | `.pixelToggle` 토글 스타일 |
| `DashboardContentView` | DashboardView.swift | 폭에 맞춰 재배치되는 단일 화면과 선택 상태 |
| `DashboardSurfaceController` | DashboardSurfaceController.swift | NSViewController 래퍼 |
| `StatusReadout` | AppDelegate.swift | 메뉴바 아이콘 + 텍스트 표시 |
