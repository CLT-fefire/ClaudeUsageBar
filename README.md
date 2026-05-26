# ClaudeUsageBar

> Claude.ai의 사용량 quota를 macOS 메뉴바에 실시간으로 표시하는 가벼운 SwiftUI 유틸리티

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-26.0%2B-blue?logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.2%2B-orange?logo=swift">
  <img alt="License" src="https://img.shields.io/badge/License-MIT-green">
  <img alt="Design" src="https://img.shields.io/badge/Design-Liquid%20Glass-purple">
</p>

claude.ai 웹에서 보는 4가지 quota — **현재 세션(5h) / 주간 전체 / 주간 Sonnet / 주간 Design** — 을 메뉴바에서 한눈에 확인할 수 있습니다. macOS 26 Tahoe의 Liquid Glass(`.clear` variant + 동적 tint)로 디자인되어 데스크탑 배경이 카드를 통과해 비쳐 보입니다.

외부 의존성 0, 백그라운드 메모리 ~35MB.

## 동작 원리

```
macOS Keychain ("Claude Code-credentials")
    │ OAuth access_token 읽기
    │ ↕ 만료 시 refresh_token으로 자동 갱신 후 write-back
    ▼
GET https://api.anthropic.com/api/oauth/usage
    │ Bearer <token>
    ▼
{ "five_hour": {...}, "seven_day": {...}, ... }
    │
    ▼
메뉴바 % + 4개 progress bar
```

- **자격증명**: Claude Desktop 또는 `claude` CLI가 로그인 시 Keychain에 저장해둔 OAuth 토큰을 그대로 활용
- **토큰 자동 갱신**: access token이 만료(임박)되거나 401이 떨어지면, Keychain의 `refresh_token`으로 Claude Code/Desktop과 **동일한 방식**으로 새 토큰을 직접 발급받아 Keychain에 다시 써넣습니다. 덕분에 Claude 본체를 열지 않아도 만료 때마다 재로그인할 필요가 없습니다 (refresh token 회전까지 반영하므로 Claude 본체 로그인과도 정합성 유지). refresh token 자체가 만료된 드문 경우에만 재로그인 안내를 띄웁니다.
- **데이터 소스**: claude.ai 웹이 호출하는 동일한 OAuth API → 웹에서 보는 값과 100% 일치
- **갱신 주기**: 5분 / 15분 / 30분 / 60분 중 선택 (기본 60분, Anthropic rate-limit 보호)
- **외부 의존성**: Foundation + SwiftUI + Security framework만 사용

## 설치

본 프로젝트는 **소스 빌드 배포 정책**을 따릅니다. 사전 빌드된 바이너리는 배포하지 않습니다 — 각자 자기 머신에서 빌드해서 (있으면) 자기 dev cert로 서명하는 게 가장 깨끗한 신뢰 체인을 만들어주기 때문입니다 ([상세 이유](#왜-바이너리-zip을-안-주나)).

```bash
git clone https://github.com/CLT-fefire/ClaudeUsageBar.git
cd ClaudeUsageBar
./make_app.sh
open ClaudeUsageBar.app
# 또는 /Applications/로 이동해서 영구 설치:
# mv ClaudeUsageBar.app /Applications/
```

요구사항:
- macOS 26.0 Tahoe 이상
- Xcode 17+ (Command Line Tools 포함, Swift 6.2)
- Claude Desktop 또는 `claude` CLI 로그인 상태 (Keychain에 자격증명 있어야 함)

빌드 시 본인의 Apple Development 인증서가 있으면 자동 감지해서 안정 서명에 사용 (Keychain ACL이 rebuild에도 유지됨). 없으면 ad-hoc 서명으로 fallback.

### 왜 바이너리 zip을 안 주나?

1. **개인 cert가 public 릴리스에 박힘** — 메인테이너 dev cert로 서명한 zip은 Dear U team ID 등 신원이 그대로 노출됨
2. **다운로드 zip은 Gatekeeper 경고를 어차피 거쳐야 함** — "다운로드 즉시 실행"이라는 장점이 사실상 무력
3. **각자 빌드가 신뢰 사슬이 더 깔끔** — 자기 cert로 서명한 자기 머신 바이너리 → 본인이 빌드 시점에 코드 감사한 그대로의 상태가 보장됨
4. **Keychain ACL이 자기 환경에 귀속** — rebuild에도 안정 (메인테이너가 cert를 바꿔도 영향 없음)

## 첫 실행 시 권한 부여

이 앱은 Keychain 항목 `Claude Code-credentials`에 **읽기**(토큰 조회)와 **쓰기**(갱신된 토큰 저장)를 합니다. macOS는 이 둘을 **별개의 권한**으로 취급하기 때문에, 처음 며칠 사용하는 동안 다음과 같은 프롬프트가 **최대 2번** 뜨고 그때마다 **로그인 비밀번호 입력**을 요구할 수 있습니다.

**① 읽기 권한** — 메뉴바 아이콘을 처음 클릭할 때:

> "ClaudeUsageBar"가 키체인 정보 **"Claude Code-credentials"** 에 접근하려고 합니다.
>
> [거부] [허용] **[항상 허용]**

**② 수정 권한** — 토큰을 처음 자동 갱신할 때(보통 access token이 만료되는 시점, 길게는 며칠 뒤):

> "ClaudeUsageBar"가 키체인 정보 **"Claude Code-credentials"** 를 **변경**하려고 합니다.
>
> [거부] [허용] **[항상 허용]**

두 프롬프트 모두 반드시 **"항상 허용"** 을 선택 + 로그인 비밀번호를 입력하세요.

- **"허용"** 만 누르면 1회용이라 다음 번에 또 묻습니다 → **"항상 허용"** 을 눌러야 그 항목에 한해 영구 통과됩니다.
- 두 권한 모두 "항상 허용" 하고 나면 그 후로는 비밀번호 없이 **완전 무음**으로 동작합니다.
- 앱을 자주 rebuild하면(특히 ad-hoc 서명 시) 서명 해시가 바뀌어 프롬프트가 다시 뜰 수 있습니다 — Apple Development 인증서로 서명하면 rebuild에도 ACL이 유지됩니다([상세](#왜-바이너리-zip을-안-주나)).

> 💡 왜 "변경" 권한까지? access token이 만료되면 앱이 Keychain의 refresh token으로 새 토큰을 발급받아 **도로 Keychain에 저장**하기 때문입니다. 이렇게 해야 Claude Code/Desktop 본체와 토큰이 어긋나지 않습니다([동작 원리](#동작-원리) 참고). 토큰은 본인 머신에서 Anthropic 본체로만 전송됩니다.

## 표시되는 Quota

| 항목 | API 키 | 의미 |
|---|---|---|
| 현재 세션 | `five_hour` | 5시간 롤링 윈도우 |
| 주간 전체 | `seven_day` | 모든 모델 합산 주간 |
| 주간 Sonnet | `seven_day_sonnet` | Sonnet 전용 주간 |
| 주간 Design | `seven_day_omelette` | Design 도구 quota |

quota 값이 `null`인 항목(해당 사용자 플랜에 없는 quota)은 표시되지 않습니다.

## 보안 고지

이 앱이 접근하는 권한:

| 무엇 | 어떻게 |
|---|---|
| Keychain의 `Claude Code-credentials` 항목 1개 | 읽기 + (토큰 갱신 시) 쓰기. macOS Keychain ACL로 사용자가 "항상 허용" 명시적 승인 |
| `api.anthropic.com` (usage 조회) | HTTPS GET |
| `console.anthropic.com` (토큰 갱신) | HTTPS POST — Keychain의 refresh token만 전송, Claude Code/Desktop이 쓰는 것과 동일 엔드포인트 |
| **외부 서버, 텔레메트리, 자동 업데이트** | **없음** |

- 토큰은 본인 머신에서 Anthropic 본체로만 나갑니다 (제3자 서버 경유 없음).
- Keychain 쓰기는 갱신된 토큰을 도로 저장하는 용도뿐이며, Claude Code/Desktop이 만든 항목 구조를 그대로 보존합니다(토큰 3개 필드만 교체).
- 권한 범위는 Claude Desktop/CLI가 이미 가지고 있는 것과 동일 (새로 권한이 생기지 않음).
- 본 코드는 MIT 라이선스로 공개되어 누구든 감사 가능.

권한이 의심스러우면 `Sources/ClaudeUsageBar/CredentialStore.swift` (Keychain 읽기/쓰기), `OAuthRefresher.swift` (토큰 갱신), `ClaudeUsageProbe.swift` (API 호출) 세 파일만 보면 전체가 다 들어있습니다.

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| `Keychain 항목을 찾을 수 없습니다` | Claude Desktop/CLI 미로그인 | `claude` 실행 후 로그인 또는 Claude Desktop 로그인 |
| Keychain 다이얼로그가 반복해서 뜸 | "허용"만 누름 (1회용) | "항상 허용" 선택 (읽기·변경 프롬프트 **둘 다**) |
| "...를 **변경**하려고 합니다" 프롬프트 | 첫 토큰 자동 갱신 시 수정 권한 요청 | **"항상 허용"** + 비밀번호 입력 (1회만, 정상 동작) |
| 자주 rebuild 후 다이얼로그 다시 뜸 | ad-hoc 서명 사용 중 (해시 변동) | Apple Development 인증서 보유 시 자동 해결 / Keychain Access.app에서 ACL 수동 추가 |
| `HTTP 401` | access token 만료 | 앱이 refresh token으로 자동 갱신·재시도 (보통 사용자 조치 불필요) |
| `자동 갱신하지 못했습니다 ... 재로그인` | refresh token까지 만료 | `claude /login` 또는 Claude Desktop 재로그인 |
| `HTTP 429` | Rate-limit | 갱신 주기를 늘리세요 (60분 권장) |
| 앱 2개가 실행되는데 메뉴바엔 안 보임 | macOS 26.0.x SwiftUI MenuBarExtra 회귀 의심 / App Translocation | 아래 [Clean Install](#clean-install) 절차 진행 |
| Gatekeeper "확인되지 않은 개발자" | dev cert 미보유 → ad-hoc 서명 | Finder에서 우클릭 → 열기 (한 번만), 이후엔 무음 동작 |

### Clean Install

이전 버전을 시도했다가 좀비 프로세스 / LaunchServices 캐시 / 잘못된 위치의 `.app` 등 잔재가 남아서 안 풀리는 경우, 이 절차로 깨끗하게 다시 시작합니다.

```bash
# 1. 좀비 프로세스 종료
killall -9 ClaudeUsageBar 2>/dev/null

# 2. 이전 잔재 정리
rm -rf ~/Downloads/ClaudeUsageBar.app /Applications/ClaudeUsageBar.app 2>/dev/null
rm -rf ~/ClaudeUsageBar /Users/Shared/Source/ClaudeUsageBar 2>/dev/null

# 3. LaunchServices 캐시 리프레시 (구버전 등록 정보 제거)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -kill -seed -r -domain local -domain system -domain user

# 4. 깨끗하게 다시 빌드
cd ~/   # 또는 원하는 경로
git clone https://github.com/CLT-fefire/ClaudeUsageBar.git
cd ClaudeUsageBar
./make_app.sh

# 5. 안정 위치(/Applications/)로 이동 + 실행
mv ClaudeUsageBar.app /Applications/
open /Applications/ClaudeUsageBar.app
```

메뉴바에 `%` 숫자가 나타나면 클릭 → Keychain 다이얼로그 → **항상 허용** + 로그인 비밀번호 (1회).

### 진단 명령

Clean Install 후에도 안 되면 아래 출력을 메인테이너에게 전달해주세요. 5분이면 끝납니다.

```bash
echo "=== OS 버전 ==="
sw_vers

echo "=== 실행 중인 프로세스 ==="
ps -ef | grep ClaudeUsageBar | grep -v grep

echo "=== 코드 서명 상태 ==="
codesign -dv --verbose=2 /Applications/ClaudeUsageBar.app 2>&1 | head -15

echo "=== quarantine 마크 ==="
xattr -l /Applications/ClaudeUsageBar.app

echo "=== 최근 크래시 로그 ==="
ls -lt ~/Library/Logs/DiagnosticReports/ClaudeUsageBar-*.ips 2>/dev/null | head -3

echo "=== 시스템 로그 (최근 5분) ==="
log show --predicate 'process == "ClaudeUsageBar" OR senderImagePath CONTAINS "ClaudeUsageBar"' \
    --last 5m --info 2>&1 | tail -50
```

#### macOS 버전 확인 권장

macOS 26.0.x에서 SwiftUI MenuBarExtra 회귀 버그가 의심되는 사례가 있습니다. 26.1+로 업데이트하면 해결될 가능성이 있어요.

```bash
softwareupdate --list   # 사용 가능한 업데이트 확인
```

26.1 이상이 보이면 시스템 설정 → 일반 → 소프트웨어 업데이트에서 적용.

## 자동 실행 설정

메뉴바 아이콘 클릭 → **로그인 시 시작** 토글 ON. `SMAppService` 표준 API로 등록되어 시스템 설정 → 일반 → 로그인 항목에도 자동 표시됨 (거기서도 끄고 켤 수 있음).

> ⚠️ `.app` 번들이 `/Applications/` 같은 안정된 위치에 있을 때 등록하세요. 빌드 디렉토리에서 토글하면 그 경로가 사라질 때 잘못된 등록이 남을 수 있습니다.

## 프로젝트 구조

```
ClaudeUsageBar/
├── Sources/ClaudeUsageBar/
│   ├── ClaudeUsageBarApp.swift   # @main + MenuBarExtra 진입점
│   ├── CredentialStore.swift     # Keychain 읽기/쓰기 (Security framework)
│   ├── OAuthRefresher.swift      # refresh_token으로 토큰 자동 갱신
│   ├── ClaudeUsageProbe.swift    # /api/oauth/usage HTTP 호출 + 파싱 + 갱신 연계
│   ├── UsageMonitor.swift        # 폴링 타이머 + 상태 (ObservableObject)
│   └── MenuContentView.swift     # 메뉴 UI (Liquid Glass cards)
├── Resources/AppIcon.icns        # 앱 아이콘 (% 글리프 squircle)
├── scripts/make_icon.swift       # 아이콘 재생성 스크립트
├── make_app.sh                   # .app 번들 패키징
└── Package.swift                 # SPM 매니페스트 (macOS 26+, Swift 6.2)
```

총 5개 Swift 파일, ~600줄. 검토 5분이면 충분.

## 라이선스

[MIT](./LICENSE) © 2026 ChulhwaJung
