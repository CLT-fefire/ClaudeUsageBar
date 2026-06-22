# ClaudeUsageBar

> Claude.ai의 사용량 quota를 macOS 메뉴바에 실시간으로 표시하는 가벼운 SwiftUI 유틸리티

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-26.0%2B-blue?logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.2%2B-orange?logo=swift">
  <img alt="License" src="https://img.shields.io/badge/License-MIT-green">
  <img alt="Design" src="https://img.shields.io/badge/Design-Liquid%20Glass-purple">
  <a href="https://github.com/CLT-fefire/ClaudeUsageBar/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/CLT-fefire/ClaudeUsageBar?label=download&logo=apple"></a>
</p>

claude.ai 웹에서 보는 4가지 quota — **현재 세션(5h) / 주간 전체 / 주간 Sonnet / 주간 Design** — 을 메뉴바에서 한눈에 확인할 수 있습니다. macOS 26 Tahoe의 Liquid Glass(`.clear` variant + 동적 tint)로 디자인되어 데스크탑 배경이 카드를 통과해 비쳐 보입니다.

외부 의존성 0, 백그라운드 메모리 ~35MB.

## 동작 원리

**v0.5.0부터** 앱이 **자체 OAuth 로그인**으로 독립 토큰을 발급받아 앱 전용 파일에 저장합니다. Claude Code/Desktop이 쓰는 공유 Keychain 항목(`Claude Code-credentials`)은 **일절 건드리지 않습니다.**

```
앱에서 직접 Claude 로그인 (PKCE OAuth, 최초 1회)
    │ access_token + refresh_token (독립 발급)
    ▼
~/.config/ClaudeUsageBar/credentials.json   (파일 0600 / 디렉토리 0700)
    │ access_token 읽기 / 만료 임박 시 자체 refresh
    ▼
GET https://api.anthropic.com/api/oauth/usage
    │ Bearer <token>
    ▼
{ "five_hour": {...}, "seven_day": {...}, ... }
    │
    ▼
메뉴바 % + 4개 progress bar
```

- **자격증명**: 앱에서 직접 Claude 계정으로 **PKCE(S256) OAuth 로그인** → 발급받은 **독립 토큰**을 앱 전용 파일(`~/.config/ClaudeUsageBar/credentials.json`, 권한 0600)에 저장합니다. 공유 Keychain 항목은 읽지도 쓰지도 않습니다.
- **토큰 자동 갱신**: access token 만료가 임박하거나 401이 떨어지면 **자체 refresh token**으로 직접 새 토큰을 발급받아 도로 파일에 써넣습니다. 독립 토큰이라 Claude 본체의 토큰 회전과 충돌하지 않습니다. refresh token 자체가 만료된 드문 경우에만 재로그인 안내를 띄웁니다.
- **데이터 소스**: claude.ai 웹이 호출하는 동일한 OAuth API → 웹에서 보는 값과 100% 일치
- **갱신 주기**: 5분 / 15분 / 30분 / 60분 중 선택 (기본 60분, Anthropic rate-limit 보호)
- **외부 의존성**: Foundation + SwiftUI + Security + CryptoKit만 사용. 서드파티 SPM 패키지 0개.

## 설치

### 1) 서명된 dmg 다운로드 (권장)

[**Releases**](https://github.com/CLT-fefire/ClaudeUsageBar/releases/latest)에서 `ClaudeUsageBar_<버전>_aarch64.dmg`를 받습니다. Dear U Developer ID로 코드 서명되어 있습니다(아직 공증 전이라 **최초 1회만 Gatekeeper 허용**이 필요합니다).

1. dmg 열기 → `ClaudeUsageBar.app`을 `Applications` 폴더로 드래그
2. **최초 실행만** 허용 절차가 필요합니다(공증 전이라 더블클릭하면 "확인되지 않은 개발자" 경고). macOS 버전에 따라 방법이 다릅니다:
   - **macOS 14(Sonoma) 이하**: Finder에서 `/Applications/ClaudeUsageBar.app` **우클릭 → 열기** → 대화상자에서 다시 **열기**
   - **macOS 15(Sequoia) 이상**: 더블클릭하면 차단됩니다(우클릭 → 열기로는 "휴지통으로 이동"·"완료" 버튼만 떠서 안 됨). **시스템 설정 → 개인정보 보호 및 보안 → 보안** 섹션에서 **"그래도 열기"** → 인증 후 한 번 더 **"그래도 열기"**
3. 이후부터는 그냥 더블클릭 / 자동 실행으로 무음 동작

> Apple Silicon(arm64) 전용입니다.

### 2) 소스에서 빌드 (대안)

코드를 직접 감사하고 빌드하고 싶다면:

```bash
git clone https://github.com/CLT-fefire/ClaudeUsageBar.git
cd ClaudeUsageBar
./make_app.sh                 # release 빌드 + .app 번들 + 코드 서명
# 배포용 dmg까지 만들려면:
# ./make_dmg.sh               # → ClaudeUsageBar_<버전>_aarch64.dmg
mv ClaudeUsageBar.app /Applications/
open /Applications/ClaudeUsageBar.app
```

빌드 요구사항:
- macOS 26.0 Tahoe 이상
- Xcode 26 (Command Line Tools 포함, Swift 6.2 toolchain)

`make_app.sh`는 로컬 키체인의 코드 서명 인증서를 자동 감지해서 안정 서명에 사용합니다. 우선순위는 **Developer ID Application → Apple Development → ad-hoc**이며, 어느 식별자도 repo에 하드코딩하지 않고 키체인에서만 읽습니다. Developer ID 인증서가 있으면 hardened runtime + secure timestamp까지 적용됩니다(공식 dmg가 그렇게 만들어집니다).

## 첫 실행 — Claude 로그인

이 앱은 **자체 PKCE OAuth 로그인**으로 독립 토큰을 발급받습니다. Claude Desktop/CLI 설치나 공유 Keychain 접근은 **필요 없습니다.**

1. 메뉴바 아이콘 클릭 → **로그인** → **Claude 로그인** 버튼 → 브라우저가 열립니다.
2. Claude 계정으로 로그인한 뒤, 콜백 페이지에 표시되는 **인증 코드를 복사**합니다.
3. 앱 입력칸에 붙여넣고 **확인**. (코드는 `코드#state` 형태 전체를 그대로 붙여넣어도 됩니다.)
4. 토큰은 `~/.config/ClaudeUsageBar/credentials.json`(파일 권한 0600)에 저장됩니다.

로그인 후 우측 메뉴바에 `%` 숫자가 표시되면 끝입니다. 코드는 발급 후 짧은 시간 내에 입력해야 하며, 시간이 지났거나 state가 어긋났으면 **로그인부터 다시** 시작하세요.

## 표시되는 Quota

| 항목 | API 키 | 의미 |
|---|---|---|
| 현재 세션 | `five_hour` | 5시간 롤링 윈도우 |
| 주간 전체 | `seven_day` | 모든 모델 합산 주간 |
| 주간 Sonnet | `seven_day_sonnet` | Sonnet 전용 주간 |
| 주간 Design | `seven_day_omelette` | Design(Opus) 도구 quota |

quota 값이 `null`인 항목(해당 사용자 플랜에 없는 quota)은 표시되지 않습니다.

## 보안 / 프라이버시

| 무엇 | 어떻게 |
|---|---|
| 토큰 저장 | 자체 PKCE 로그인으로 발급한 **독립** OAuth 토큰을 `~/.config/ClaudeUsageBar/credentials.json`(파일 0600 / 디렉토리 0700)에만 저장. 공유 Keychain 항목(`Claude Code-credentials`)은 읽지도 쓰지도 않음 |
| `claude.ai` | 로그인(PKCE authorize) — HTTPS |
| `platform.claude.com` | 토큰 교환·갱신 — HTTPS POST |
| `api.anthropic.com` | 사용량 조회 — HTTPS GET (`Authorization: Bearer`) |
| 외부 서버 · 텔레메트리 · 자동 업데이트 | **없음** |

- 토큰은 본인 머신에서 Anthropic 엔드포인트로만 전송됩니다 (제3자 서버 경유 없음).
- 분석 도구·텔레메트리 전무. 오픈소스(MIT)라 누구든 직접 감사 가능.
- 권한이 의심스러우면 `OAuthLogin.swift`(PKCE 로그인), `CredentialStore.swift`(파일 저장), `OAuthRefresher.swift`(토큰 갱신), `ClaudeUsageProbe.swift`(API 호출) 네 파일만 보면 전부 들어 있습니다.

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| `로그인이 필요합니다` | 아직 미로그인 | 메뉴 → **로그인** → **Claude 로그인** |
| 인증 코드가 거부됨 | 코드 만료 / state 불일치 | **로그인부터 다시** 시작. `코드#state` 전체를 붙여넣기 |
| Gatekeeper "확인되지 않은 개발자" | 서명됐으나 공증 전 (또는 미서명 빌드) | macOS 14↓는 **우클릭 → 열기**, 15+는 **시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기"**. 또는 `xattr -dr com.apple.quarantine /Applications/ClaudeUsageBar.app` |
| `HTTP 401` | access token 만료 | 앱이 refresh token으로 자동 갱신·재시도 (보통 조치 불필요) |
| `자동 갱신하지 못했습니다 ... 재로그인` | refresh token까지 만료 | 메뉴 → **로그아웃** 후 다시 로그인 |
| `HTTP 429` | Rate-limit | 갱신 주기를 늘리세요 (60분 권장) |
| 앱은 실행되는데 메뉴바에 안 보임 | macOS 26.0.x SwiftUI MenuBarExtra 회귀 의심 / App Translocation | 아래 [Clean Install](#clean-install) 또는 macOS 26.1+ 업데이트 |

### Clean Install

이전 버전을 시도했다가 좀비 프로세스 / LaunchServices 캐시 / 잘못된 위치의 `.app` 등 잔재가 남아 안 풀리는 경우, 이 절차로 깨끗하게 다시 시작합니다.

```bash
# 1. 좀비 프로세스 종료
killall -9 ClaudeUsageBar 2>/dev/null

# 2. 이전 잔재 정리
rm -rf ~/Downloads/ClaudeUsageBar.app /Applications/ClaudeUsageBar.app 2>/dev/null

# 3. LaunchServices 캐시 리프레시 (구버전 등록 정보 제거)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -kill -seed -r -domain local -domain system -domain user

# 4. dmg 다시 받아 /Applications/로 드래그 후 실행
#    (또는 소스에서: git clone ... && cd ClaudeUsageBar && ./make_app.sh && mv ClaudeUsageBar.app /Applications/)
open /Applications/ClaudeUsageBar.app
```

> 토큰까지 완전 초기화하려면 `rm -rf ~/.config/ClaudeUsageBar` 후 다시 로그인하세요.

메뉴바에 `%` 숫자가 나타나면 클릭 → 사용량 카드 4개가 보입니다. 미로그인 상태면 **로그인 → Claude 로그인** 절차부터.

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
│   ├── OAuthLogin.swift          # 자체 PKCE(S256) OAuth 로그인 + 코드↔토큰 교환
│   ├── CredentialStore.swift     # 독립 토큰을 앱 전용 파일에 저장 (~/.config/ClaudeUsageBar)
│   ├── OAuthRefresher.swift      # refresh_token으로 토큰 자동 갱신
│   ├── ClaudeUsageProbe.swift    # /api/oauth/usage HTTP 호출 + 파싱 + 갱신 연계
│   ├── UsageMonitor.swift        # 폴링 타이머 + 상태 (ObservableObject)
│   ├── LaunchAtLogin.swift       # SMAppService 로그인 시 자동 실행 토글
│   ├── MenuContentView.swift     # 메뉴 UI (테마별 카드/게이지)
│   └── Theme.swift               # 테마 시스템 (6종: 유리/HUD/터미널/홀로/청사진/메탈릭)
├── Resources/AppIcon.icns        # 앱 아이콘 (% 글리프 squircle)
├── scripts/make_icon.swift       # 아이콘 재생성 스크립트
├── make_app.sh                   # .app 번들 패키징 + 코드 서명
├── make_dmg.sh                   # 배포용 dmg 패키징 + 서명
└── Package.swift                 # SPM 매니페스트 (macOS 26+, Swift 6.2)
```

총 9개 Swift 파일. 검토 10분이면 충분.

## 버전 / 로드맵

최신: **v0.10.1** (2026-06-22) — [릴리스 노트](https://github.com/CLT-fefire/ClaudeUsageBar/releases/latest)

- v0.1.0 — 메뉴바 % 표시 + 4개 quota 진행률
- v0.2.0 — Liquid Glass 디자인 + 갱신 주기 설정
- v0.3.0 — SMAppService 기반 로그인 시 자동 실행 토글
- v0.4.0 — OAuth 토큰 자동 갱신
- v0.5.0 — 독립 OAuth 로그인 전환 (공유 Keychain 의존 제거, 재인증 팝업 문제 해결)
- v0.6.0 — **서명된 바이너리 배포 전환** (Dear U Developer ID 서명 + dmg를 GitHub Release로 배포)
- v0.7.0 — 주간 리셋까지 남은 시간 표시 + 부정확한 "다음 갱신" 카운트다운 제거
- v0.8.0 — 2026-06-15 세분화 제한 정책 반영 (limits 배열 데이터 주도 파싱)
- v0.9.0 — 로컬 로그 기반 사용량 차트
- v0.10.0 — **테마 시스템 (유리 · HUD · 터미널 · 홀로 · 청사진 · 메탈릭 6종)**
- v0.10.1 — 테마 폴리시 (전 테마 다크 고정, 홀로 sun-stripe, 터미널 green 텍스트 전면, HUD 스캔라인, 테마별 텍스트 계층색)

## 라이선스

[MIT](./LICENSE) © 2026 ChulhwaJung
