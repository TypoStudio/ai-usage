# ai-usage — 기획서 (v0.2 초안)

`~/bin/ai-usage` 셸 스크립트(Claude Code 3계정 + Codex 3계정 사용량 조회)를
**macOS 바탕화면 위젯(WidgetKit)** 으로 옮긴다. 프로바이더(Claude / Codex)별로 독립된 위젯을 두고,
**계정 하나 = Apple Watch 활동 링 모양의 게이지 하나**(링 3개 = 5시간 / 주간 전체 / 주간 Fable)로 사용량을 보여준다.
상세 정보는 앱 창에서 본다. 메뉴 바 아이템은 두지 않는다.

> v0.2 변경: 메뉴 바(NSStatusItem) 안 → 바탕화면 WidgetKit 위젯. 게이지는 링 3개 = 한도 3개.
> §2 결정 뒤집힘, §3·§5·§7·§8·§9·§10 반영.
>
> v0.3(구현): M1~M4 구현 완료. 구현 중 확정된 사항은 각 절에 **[구현]** 으로 표시.

---

## 1. 목표

- 터미널을 열지 않고도 바탕화면에서 각 계정의 남은 한도를 즉시 확인한다.
- 프로바이더별로 **따로 배치할 수 있는 위젯**을 제공한다 (Claude만, Codex만, 둘 다).
- 계정(환경) 추가·삭제·순서 변경을 앱 안에서 처리한다. 스크립트처럼 배열을 손으로 고치지 않는다.
- 만료된 토큰은 사용자가 손대지 않아도 갱신한다 (Claude: `claude doctor` 방식 재사용).
- 한도가 임계치를 넘으면 알린다 (예: 주간 90%, 크레딧 고갈).

## 2. "위젯"의 해석 — 두 가지 후보와 선택

| | A. 메뉴 바 위젯 (NSStatusItem) | B. WidgetKit 데스크톱/알림센터 위젯 |
|---|---|---|
| 구현 방식 | SwiftPM 단일 실행 파일, focus-play·Snatch와 동일 | Xcode 프로젝트 + Widget Extension(appex) 필수 |
| 서명 | ad-hoc(`codesign -s -`)로 충분 | 익스텐션은 App Group·entitlements 필요, ad-hoc으로는 로드가 불안정 |
| 키체인 접근 | 앱 프로세스에서 직접 읽음 (최초 1회 "항상 허용") | 익스텐션은 키체인 프롬프트를 띄울 수 없음 → 앱이 스냅샷을 써주고 위젯은 읽기만 |
| 갱신 주기 | 앱이 자유롭게 (1~5분) | 시스템 예산에 묶임 (실질 15분+) |
| 서브프로세스(`claude doctor`) | 가능 | 익스텐션에서 불가 |
| 항상 보임 | 메뉴 바에 상시 | 데스크톱에 배치 시 상시, 알림센터는 열어야 보임 |

**결정(v0.2): B(바탕화면 위젯)로 간다.** 표의 제약은 역할 분리로 푼다.

- **앱**이 키체인 읽기·`claude doctor`·API 호출을 모두 맡고, 결과를 App Group 컨테이너의 `snapshot.json`에 쓴 뒤
  `WidgetCenter.shared.reloadAllTimelines()`를 호출한다.
- **위젯 익스텐션**은 그 파일을 읽어 링 게이지를 그리기만 한다. 네트워크·키체인·서브프로세스에 손대지 않는다.
- 앱은 창을 닫아도 백그라운드에서 계속 돌며 갱신한다(로그인 시 실행 옵션). 위젯을 클릭하면 앱의 상세 창이 열린다.
- 서명: 위젯 익스텐션 + App Group은 Xcode 팀 서명이 필요하다(무료 Apple ID 팀으로 로컬 실행 가능, 배포는 Developer ID). → §8, §10.

## 3. 사용자 시나리오

1. 앱을 한 번 실행한 뒤 바탕화면 우클릭 → `위젯 편집…` → `AI Usage`에서 **Claude 위젯**과 **Codex 위젯**을 배치한다.
   위젯 하나(medium)에 **계정 수만큼 링 게이지**가 가로로 나열된다(3계정 = 게이지 3개).
   게이지 하나는 동심원 링 3개, **링 하나 = 한도 하나**(5시간 / 주간 전체 / 주간 Fable).
2. 위젯 클릭 → 앱의 상세 창이 열리고 계정별 카드가 세로로 나열된다. 스크립트 출력과 같은 정보:
   이메일, 플랜, 각 한도의 막대·퍼센트·리셋까지 남은 시간, 경고 뱃지.
3. 창 하단: `지금 새로고침`, `설정…`. 창을 닫아도 앱은 백그라운드에서 갱신을 계속한다.
4. 설정 창 → 계정 탭에서 `~/.claude-*`, `~/.codex-*` 자동 탐지 결과를 체크박스로 켜고 끈다.
   직접 경로 추가도 가능. 위젯 탭에서 프로바이더별 표시 여부·아이콘 스타일·갱신 주기·알림 임계치.
5. 토큰이 만료된 계정은 카드에 `갱신 중…`이 잠깐 뜨고 자동으로 채워진다.
   실패하면 `cld2 한 번 실행 필요` 안내와 함께 터미널 명령을 복사할 수 있는 버튼.

## 4. 데이터 소스 (스크립트에서 검증된 것 그대로)

### 4.1 Claude Code
- 계정 = `CLAUDE_CONFIG_DIR` 하나. 기본 탐지: `~/.claude-*` 중 `.claude.json`이 있는 디렉토리
  (`.claude-shared`처럼 설정 파일이 없는 것은 제외).
- 이메일: `<dir>/.claude.json` → `oauthAccount.emailAddress`
- 자격 증명: 키체인 generic password, service = `Claude Code-credentials-<sha256(dir 절대경로) 앞 8 hex>`.
  없으면 `<dir>/.credentials.json` 폴백.
  **[구현]** 키체인은 `Security` API 대신 `/usr/bin/security find-generic-password -w` 로 읽는다.
  Claude Code 항목의 ACL 에 이미 들어 있어 허용 창이 뜨지 않고, 앱을 다시 서명해도 다시 묻지 않는다. JSON 필드 `claudeAiOauth.{accessToken, expiresAt(ms), subscriptionType}`.
- 사용량: `GET https://api.anthropic.com/api/oauth/usage`
  헤더 `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<version>`.
  응답 `.limits[]` → `kind`, `scope.model.display_name`(선택), `percent`, `resets_at`(ISO), `severity`.
  **[구현]** `kind` 는 `session` / `weekly_all` / `weekly_scoped`(모델별). `resets_at` 은 마이크로초 6자리라 밀리초로 잘라 파싱.
- **토큰 갱신**: `expiresAt < now` 이면 `CLAUDE_CONFIG_DIR=<dir> claude doctor` 를 stdin 닫고 30초 타임아웃으로 실행 → 키체인 다시 읽기.
  OAuth 토큰 엔드포인트 직접 호출은 curl 기준 429가 반환되어 채택하지 않는다.
- `claude` 실행 파일 위치: `PATH` 탐색 + `~/.local/share/claude/versions/*` 폴백. 설정에서 수동 지정 가능.

### 4.2 Codex
- 계정 = `~/.codex-*/auth.json` 하나. 필드 `tokens.{access_token, account_id, id_token, refresh_token}`, `last_refresh`.
- 이메일: `id_token` JWT payload의 `email`.
- 사용량: `GET https://chatgpt.com/backend-api/wham/usage`
  헤더 `Authorization: Bearer <access_token>`, `ChatGPT-Account-Id: <account_id>`, `User-Agent: codex-cli/<version>`.
  응답 `.plan_type`, `.rate_limit_reached_type.type`(예: `workspace_owner_credits_depleted`),
  `.rate_limit.{primary_window,secondary_window}` → `limit_window_seconds`(18000=5h, 604800=7d), `used_percent`, `reset_at`(epoch), `reset_after_seconds`.
  **[구현]** 팀 플랜은 `primary_window` 가 7d 이고 `secondary_window` 는 null 이다. 그래서 링은 순서가 아니라 창 길이로 정한다.
- **토큰 갱신**: 1차 범위에서는 자동 갱신 없음. 401/403이면 카드에 `cdxN 한 번 실행` 안내.
  (`refresh_token`이 있으므로 갱신 가능성은 있으나 엔드포인트·클라이언트 ID 검증 후 2차에서 검토.)
- 같은 Team 워크스페이스에 속한 계정은 `account_id`가 같다 → 크레딧 고갈 경고는 워크스페이스 단위로 한 번만 묶어 표시.

### 4.3 공통 모델

```
Provider { id: claude|codex, accounts: [Account] }
Account  { id, label(이메일), configPath, enabled, order }
Snapshot { accountId, fetchedAt, plan, warning?, limits: [Limit], error? }
Limit    { name("session"/"weekly_all"/"5h"/"7d"…), percent, resetsAt: Date?, severity? }
```

스냅샷은 App Group 컨테이너 `~/Library/Group Containers/<group id>/snapshot.json`에 기록한다.
앱이 쓰고 위젯이 읽는 유일한 통로다. 토큰은 넣지 않는다(퍼센트·리셋 시각·오류 문자열만).

## 5. UI 명세

### 5.1 링 게이지 (계정당 1개)
Apple Watch 활동 링과 같은 모양. **게이지 하나 = 계정 하나**, 동심원 링 3개 = 한도 3개.

| 링 | Claude | Codex | 색 (focus-play 팔레트, Apple 활동 링과 구분) |
|---|---|---|---|
| 바깥 | `session` (5시간) | `primary` (5h) | 호박 #FFB547 |
| 가운데 | `weekly_all` (주간 전체) | `secondary` (7d) | 보라 #B36BFF |
| 안쪽 | 주간 모델별 (`display_name` = Fable) | 없음 → 어두운 트랙만 | 민트 #4DE3C1 |

- 링이 찬 정도 = 그 한도의 `percent`(0~100%). 12시에서 시작해 시계 방향으로 찬다.
  Apple의 링과 반대로 **가득 찰수록 나쁘다**.
- 임계치(기본 90%, 설정 값) 이상·경고 플래그 = 그 링만 빨강. 오류·토큰 만료 = 게이지 전체가 회색 점선 링.
- 게이지 아래에 라벨(`cld1`)과 가장 높은 퍼센트. **[구현]** 링 가운데 숫자는 안쪽 링을 가려서 뺐다.
- `RingGaugeView`(계정 1개)는 위젯과 앱 상세 창이 같은 코드를 쓴다.

### 5.2 위젯 (WidgetKit, 프로바이더별 2종)
`ClaudeUsageWidget`, `CodexUsageWidget` — 위젯 갤러리에 따로 뜬다. 배경은 이미지처럼 검정.

| 패밀리 | 내용 |
|---|---|
| systemSmall | 게이지 1개. 어느 계정인지는 위젯 편집(AppIntent 설정)에서 고름 |
| systemMedium (기본) | 게이지 3개 가로 나열. 계정이 3개 넘으면 앞 3개, 나머지는 상세 창에만 |
| systemLarge | 게이지 3개 + 각 한도의 퍼센트·리셋까지 남은 시간 텍스트 |

- 위젯 머리에 `갱신 21:15`. 스냅샷이 max(10분, 갱신 주기×2 + 1분)보다 오래되면 `앱 실행 필요` 배지.
  위젯은 앱 설정을 못 읽으므로 임계치·갱신 주기도 스냅샷에 함께 쓴다.
- 위젯 전체가 `widgetURL(aiusage://open?provider=claude)` → 앱 상세 창이 해당 프로바이더 위치로 열린다.
- 타임라인: 항목 1개(현재 스냅샷), 정책 `.never`. 갱신은 전적으로 앱의 `reloadAllTimelines()`에 의존한다.

### 5.3 상세 창 — 앱 윈도우 (SwiftUI)
```
┌ Claude Code ───────────────────────────┐
│ cld1  alex@…            max            │
│   session      ▓░░░░░░░░░  6%  4h 54m  │
│   weekly_all   ▓░░░░░░░░░  6%  6d 11h  │
│   weekly/Fable ▓░░░░░░░░░  7%  6d 11h  │
│ cld2  alex.work@…       max            │
│   …                                    │
│ cld3  alex.lab@…        ⟳ 갱신 중…     │
├────────────────────────────────────────┤
│ 마지막 갱신 21:15          [새로고침] [설정…] │
└────────────────────────────────────────┘
```
- 라벨(`cld1`)은 디렉토리 접미사에서 자동 생성, 설정에서 변경 가능.
- 카드 우클릭/… 메뉴: `터미널에서 열기`(`cld2` 명령 복사), `이 계정 숨기기`.

### 5.4 설정 창
- **계정**: 프로바이더별 탐지 목록(경로·이메일·상태) + 체크박스 + 드래그 정렬 + `경로 추가…`. 순서가 곧 위젯의 게이지 순서.
  **[구현]** 탐지 순서는 `one, two, three…` 먼저, 나머지 이름순. 새로 탐지된 계정은 프로바이더별 3개까지만 켜진 채 들어온다.
- **갱신**: 갱신 주기(1/2/5/10분).
- **알림**: 임계치(기본 90%), 크레딧 고갈·토큰 갱신 실패 알림 on/off.
- **일반**: 로그인 시 실행(기본 on — 안 켜면 위젯이 오래된 값에 멈춘다), `claude`/`codex` 실행 파일 경로, 스냅샷 파일 위치 열기.

## 6. 갱신·알림 정책
- 주기 갱신(기본 2분) + 상세 창 열 때 즉시 갱신 + 수동 버튼. 절전 복귀 시 1회.
- 갱신이 끝날 때마다 스냅샷을 쓴다. `reloadAllTimelines()` 는 값이 바뀌었거나 마지막 리로드 후 5분이 지났을 때만 부른다.
  리로드 예산을 아끼면서도, 앱이 살아 있는데 위젯이 `앱 실행 필요` 로 바뀌지 않게 하기 위해서다.
- 서브프로세스는 타임아웃 시 SIGTERM, 3초 뒤 SIGKILL. 출력은 파이프가 아닌 임시 파일로 받아 손자 프로세스 때문에 멈추지 않게 한다.
- 계정별 병렬 요청, 계정당 15초 타임아웃. 한 계정 실패가 다른 계정을 막지 않는다.
- 토큰 갱신(`claude doctor`)은 **모든 계정을 통틀어 한 번에 하나씩**, 계정당 10분에 1회까지. 타임아웃 90초.
- **[사고 2026-09-24]** 새벽 다크웨이크(화면 꺼진 채 41초 깨어남) 중에 cld2·cld3 의 `claude doctor` 가 동시에 돌다가
  잠자기로 끊겼고, 1초 뒤 두 계정의 키체인 자격 증명이 같은 초에 비워졌다(`expiresAt: 0`, `refreshToken` 없음).
  갱신 토큰이 교체된 뒤 저장되지 못한 것으로 추정. 대책:
  - 화면이 꺼져 있거나 잠자기 중이면 갱신 자체를 하지 않는다(`screensDidSleep`/`willSleep` → 멈춤, `screensDidWake`/`didWake` → 즉시 갱신).
  - doctor 차례가 왔을 때 화면이 꺼졌으면 건너뛴다.
  - 갱신 토큰이 없으면 doctor 를 돌리지 않고 `다시 로그인 필요`(명령 + `/login` 안내)를 보여 준다.
  - 만료 전 미리 갱신은 doctor 실행 횟수만 늘려 같은 위험을 키우므로 넣지 않는다.
- 알림(UNUserNotification): 임계치 **넘는 순간** 1회, 리셋 후 다시 무장. 크레딧 고갈 플래그도 동일.

## 7. 기술 스택·저장소 구조

- Swift 6, SwiftUI, WidgetKit + AppIntents, **macOS 14+** (바탕화면 위젯은 Sonoma부터).
- 외부 의존성 없음. 네트워크는 `URLSession`, 키체인은 `Security` 프레임워크, 서브프로세스는 `Process`.
- **Xcode 프로젝트 필수**(위젯 익스텐션은 SwiftPM만으로 못 만든다). `project.yml` + xcodegen으로 생성해 `.xcodeproj`는 커밋하지 않는다.
- 타깃 3개: 앱(샌드박스 **끔** — 키체인·홈 디렉토리·서브프로세스), 위젯 익스텐션(샌드박스 켬, App Group만),
  공용 로컬 패키지 `AIUsageCore`(로직·모델·링 뷰 — `swift test`로 단독 테스트).

```
ai-usage/
├─ project.yml                 xcodegen 정의 (앱 + 위젯 + App Group entitlements)
├─ AIUsage/                    앱 타깃
│  ├─ AIUsageApp.swift, AppDelegate.swift(백그라운드 유지, URL 스킴)
│  ├─ Refresh/                 RefreshScheduler.swift(주기 갱신 → 스냅샷 → reloadAllTimelines)
│  ├─ UI/                      DetailWindow.swift, SettingsView.swift
│  └─ Resources/               Localizable.xcstrings (ko/en/ja)
├─ AIUsageWidget/              위젯 익스텐션 타깃
│  ├─ ClaudeUsageWidget.swift, CodexUsageWidget.swift, UsageTimelineProvider.swift
│  └─ AccountSelectionIntent.swift (small 패밀리 계정 선택)
├─ Packages/AIUsageCore/       공용 SwiftPM 패키지
│  ├─ Sources/AIUsageCore/
│  │  ├─ Providers/            Provider.swift(프로토콜), ClaudeProvider.swift, CodexProvider.swift
│  │  ├─ Accounts/             AccountDiscovery.swift, AccountStore.swift
│  │  ├─ Auth/                 KeychainReader.swift, ClaudeTokenRefresher.swift(claude doctor)
│  │  ├─ Model/                Snapshot.swift, Limit.swift, SnapshotStore.swift(App Group 경로)
│  │  └─ Views/                RingGaugeView.swift
│  └─ Tests/AIUsageCoreTests/  응답 JSON 파싱, 키체인 서비스명 해시, 남은 시간 포맷, 링 값 매핑
├─ scripts/build-app.sh        xcodegen → xcodebuild → .app → dmg
├─ assets/icon.svg             앱 아이콘 원본 (focus-play 와 같은 틀 + 활동 링) → icon-1024.png → AIUsage/Assets.xcassets
├─ docs/PLAN.md
└─ README.md (영/한)
```

- 배포: GitHub `TypoStudio/ai-usage` + `typostudio/tap` Cask. 위젯 익스텐션은 팀 서명이 없으면 시스템이 로드하지 않으므로
  ad-hoc 배포는 불가 — Developer ID 서명 + 공증이 전제. 없으면 "소스에서 직접 빌드(자기 Apple ID로 서명)"만 안내.

## 8. 리스크·제약

| 항목 | 내용 | 대응 |
|---|---|---|
| 키체인 접근 프롬프트 | Claude Code가 만든 항목이라 첫 읽기마다 macOS가 허용 여부를 묻는다 | **[구현] 해소** — `/usr/bin/security` 경유로 읽어 프롬프트 없음 |
| 위젯 서명·App Group | 익스텐션과 App Group entitlement는 팀 서명 필수. ad-hoc으로는 위젯이 갤러리에 안 뜬다 | 개발은 Xcode 자동 서명(개인 팀). 배포는 Developer ID 확보 후. §10-5 |
| 위젯 리로드 예산 | `reloadAllTimelines()`를 너무 자주 부르면 시스템이 무시할 수 있다 | 값 변경 시에만 호출, 최소 간격 1분. 위젯에 `갱신 hh:mm` 표기로 지연을 드러냄 |
| 앱이 안 떠 있음 | 위젯은 스스로 데이터를 못 가져오므로 앱이 죽으면 값이 멈춘다 | 로그인 시 실행 기본 on, 10분 이상 오래된 스냅샷은 위젯에 `앱 실행 필요` 배지 + 클릭 시 앱 실행 |
| 비공식 API | `/api/oauth/usage`, `/backend-api/wham/usage` 모두 문서화되지 않음 | 파싱 실패 시 카드에 원본 오류 노출, `--raw`에 해당하는 "응답 보기" 메뉴 |
| `claude doctor` 부작용 | 실행 시간·출력 형식이 버전마다 달라질 수 있음 | 타임아웃 30초, 결과 판정은 키체인 `expiresAt` 재확인으로만 |
| Codex 토큰 만료 | 자동 갱신 미지원 | 명령 안내 + 클립보드 복사. 2차에서 리프레시 엔드포인트 검토 |
| 요청 빈도 | 사용량 API에 레이트 리밋이 있을 수 있음 | 기본 2분, 429 수신 시 지수 백오프(최대 30분) |

## 9. 로드맵

| 단계 | 범위 | 완료 기준 |
|---|---|---|
| M0 기획 | 이 문서 | 사용자 확인 ✅ |
| M1 코어 | `AIUsageCore`: 계정 탐지, Claude/Codex 조회, App Group 스냅샷, 단위 테스트 | `swift test` 통과, 스냅샷이 스크립트 출력과 일치 ✅ |
| M2 위젯 | xcodegen 프로젝트, 앱(백그라운드 갱신) + Claude/Codex 위젯 medium, 링 게이지 | 바탕화면에 3+3 계정이 게이지 6개(3링씩)로 뜨고 2분마다 바뀜 ✅(렌더링 검증, 바탕화면 배치는 사용자) |
| M3 상세 창·갱신·알림 | 위젯 클릭 → 상세 창, `claude doctor` 자동 갱신, 임계치 알림, 백오프 | 만료 토큰이 사용자 개입 없이 채워짐 ✅ |
| M4 설정·배포 | 설정 창, small/large 패밀리, 로그인 시 실행, build-app.sh, README, Cask | `brew install --cask typostudio/tap/ai-usage` ✅ (공증 없음 → quarantine 해제 안내) |
| M4.5 배포 | GitHub 저장소·릴리즈, 자동 업데이트(focus-play UpdateService), 설정 `정보` 탭(GitHub·Buy Me a Coffee), README·스크린샷 | ✅ |
| M5 (선택) | 메뉴 바 미니 게이지 — 같은 스냅샷을 NSStatusItem에 그림 | 위젯 없이도 쓰고 싶을 때 |

## 10. 확인이 필요한 질문

1. ~~메뉴 바 아이템 구성~~ → v0.2에서 확정: 바탕화면 위젯, 프로바이더별 2종, 계정당 게이지 1개(링 = 한도).
2. ~~메뉴 바 숫자의 기준~~ → 링이 한도별로 따로 보이므로 불필요.
5. **Apple Developer 계정(Developer ID) 유무.** 현재는 Apple Development 인증서로 서명해 배포한다. 공증이 없어 첫 실행에 quarantine 해제가 필요하다. Developer ID 를 확보하면 `SIGN_IDENTITY` 만 바꿔 공증까지 붙인다.
6. 링 색을 링 고정(기본안, 이미지처럼 3색)으로 할지, 사용률에 따라 바꿀지(초록→주황→빨강).
7. 안쪽 링의 모델별 한도: Fable 고정 vs 응답에 있는 첫 번째 모델별 한도. 모델별 한도가 없는 플랜은 트랙만 표시.
8. 앱에 Dock 아이콘을 둘지(기본안: 둔다, 창 닫아도 실행 유지) vs `LSUIElement`로 숨길지.
3. Codex 자동 갱신을 1차에 넣을지 (리프레시 엔드포인트 검증 작업 필요).
4. 앱 이름: `ai-usage` 그대로 vs 브랜딩 (focus-play → FocusPlay처럼 번들명은 `AIUsage`).
