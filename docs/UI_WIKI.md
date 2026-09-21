# RetroStats UI 위키

메뉴바 앱의 모든 화면 요소와 컴포넌트의 이름·역할·상태를 정의한다. 트랜지션 이슈 재현이나 UI 변경 시 이 문서의 용어를 기준으로 맥락을 전달한다.

## 화면 구조 개요

```
┌─ Popover (TransparentPopover, 400×600) ────────────────────┐
│ ┌─ Header ──────────────────────────────────────────────┐ │
│ │ [뒤로] [타이틀]                          [실시간 LED] [설정] │ │
│ └────────────────────────────────────────────────────────┘ │
│ ┌─ Page Area (전환 애니메이션 영역) ───────────────────────┐ │
│ │ overview | processes | storage | settings 중 1페이지    │ │
│ └────────────────────────────────────────────────────────┘ │
│ ┌─ Action Bar (storage 페이지에서만) ─────────────────────┐ │
│ │ [공용 캐시 포함 토글] / [선택 정리 버튼] 등               │ │
│ └────────────────────────────────────────────────────────┘ │
│ ┌─ Footer ────────────────────────────────────────────────┐ │
│ │ [코어·메모리]                          [3초마다 갱신]      │ │
│ └────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────┘
```

## 페이지 (DashboardPage)

`DashboardPage` enum: `overview`, `processes`, `storage`, `settings`

`model.page`가 바뀌면 `TransitionContainer`가 변경을 감지해 전환한다. 전환 중 요청은 마지막 페이지를 기억했다가 현재 효과가 끝난 뒤 실행한다. macOS의 동작 줄이기 설정에서는 즉시 전환한다.

## Header

| 요소 | 심볼 | 위치 | 설명 |
| --- | --- | --- | --- |
| 뒤로 버튼 | `Image(chevron.left)` | 좌측 | `model.page != .overview`일 때 표시. `model.page = .overview` |
| 타이틀 | `Text(title)` | 좌측 | 페이지별 제목 (RetroStats / 프로세스 / 스토리지 정리 / 설정) |
| 실시간 표시 | `Text("실시간")` + `PixelLED` | 우측 | `.overview`에서만 표시 |
| 설정 버튼 | `PixelSliders` | 우측 | `model.page = .settings` |

## Footer

| 요소 | 설명 |
| --- | --- |
| 코어·메모리 | `\(activeProcessorCount)코어 · \(bytes(totalMemory))` |
| 갱신 주기 | `3초마다 갱신` |

---

## Overview 페이지 (`overview`)

대시보드 메인 화면. 4개 섹션으로 구성.

### Overview 섹션

| 요소 | 심볼 | 설명 |
| --- | --- | --- |
| CPU 카드 | `metric(order: .cpu, ...)` | LCDScreen에 큰 숫자% + HistoryLine. 탭 시 `.processes` 전환 |
| 메모리 카드 | `metric(order: .memory, ...)` | LCDScreen에 큰 숫자% + HistoryLine. 탭 시 `.processes` 전환 |
| 네트워크 | `Label("네트워크")` | 다운로드(↓) / 업로드(↑) 속도 |
| 스토리지 카드 | `Button { model.page = .storage }` | 디스크 % + UsageBar + 여유 공간 + 정리 후보. 탭 시 `.storage` 전환 |
| 배터리/활성상태 | `Text(battery)` + `Button("활성 상태 보기")` | 배터리 상태 + 활성 상태 보기 실행 |

### Metric 카드 구조 (`metric(order:value:subtitle:history:)`)

```
┌─ Metric Card (Button, .plain) ───────┐
│ CPU                       ↗           │  ← 라벨 + 화살표
│ ┌─ LCDScreen ──────────────────────┐ │
│ │  42%                              │ │  ← 큰 숫자 (pixel 40)
│ │  ▁▂▃▅▇▆▄▃▂▁  (HistoryLine)       │ │  ← 히스토리 그래프
│ └───────────────────────────────────┘ │
│ 전체 코어 사용률                        │  ← 부제목
│ 상위 프로세스                           │  ← 섹션 라벨
│ Xcode  45.2%                           │  ← 상위 3개 프로세스
│ ...                                    │
└───────────────────────────────────────┘
```

---

## Processes 페이지 (`processDetails`)

상위 프로세스 상세 화면.

| 요소 | 설명 |
| --- | --- |
| 정렬 Picker | `.segmented` (CPU / 메모리) |
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
| 디스크 요약 | `Text(bytes(disk.free))` + `UsageBar` | `disk != nil` | 여유 공간 + 사용률 바 |
| DerivedData 헤더 | `Text("DerivedData")` | 항상 | 8시간 기준 안내 |
| PixelHourglass | `PixelHourglass` | `busy && cleaning` | 정리 중 표시 (조회 중에는 미표시) |
| 새로고침 버튼 | `PixelRefresh(animating:)` | 항상 | `busy`면 애니메이션 + 비활성화 |
| 스캔 진행 텍스트 | `Text("조회 중: \(name)")` | `busy && !cleaning` | 현재 검사 중인 경로 |
| 정리 진행 텍스트 | `Text("선택한 캐시 정리 중…")` | `busy && cleaning` | 정리 중 메시지 |
| 에러 | `Text(error)` | `lastError != nil` | 빨간색, 텍스트 선택 가능 |
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
| `LCDScreen` | LCD.swift | 어두운 배경 + 흰 텍스트 LCD 화면 컨테이너 |
| `LCDPanelBackground` | LCD.swift |lcdPanel 모디파이어 (패널 배경) |
| `UsageBar` | LCD.swift | 사용률 바 (디스크, 정리 진행) |
| `HistoryLine` | LCD.swift | 히스토리 그래프 (CPU/메모리) |
| `PixelButtonStyle` | PixelControls.swift | `.pixel` / `.pixelPrimary` / `.pixelGhost` 버튼 스타일 |
| `PixelToggleStyle` | PixelControls.swift | `.pixelToggle` 토글 스타일 |
| `TransparentPopover` | Popover.swift | 메뉴바 투명 팝오버 |
| `DashboardSurfaceController` | DashboardSurfaceController.swift | NSViewController 래퍼 |
| `StatusReadout` | AppDelegate.swift | 메뉴바 아이콘 + 텍스트 표시 |
