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
    │ OAuth access_token 읽기 (read-only)
    ▼
GET https://api.anthropic.com/api/oauth/usage
    │ Bearer <token>
    ▼
{ "five_hour": {...}, "seven_day": {...}, ... }
    │
    ▼
메뉴바 % + 4개 progress bar
```

- **자격증명**: Claude Desktop 또는 `claude` CLI가 로그인 시 Keychain에 저장해둔 OAuth 토큰을 그대로 활용 (본 앱은 **읽기만**, 갱신은 Claude 본체가 자동 처리)
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

메뉴바 아이콘을 처음 클릭하면 macOS가 묻습니다:

> "ClaudeUsageBar"가 키체인 정보 **"Claude Code-credentials"** 에 접근하려고 합니다.
>
> [거부] [허용] **[항상 허용]**

→ **"항상 허용"** 선택 + 로그인 비밀번호 입력 = 그 후로는 무음 동작.

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
| Keychain의 `Claude Code-credentials` 항목 1개 | macOS Keychain ACL (사용자가 "항상 허용" 명시적 승인) |
| `api.anthropic.com` 1개 URL | HTTPS GET 호출 |
| **외부 서버, 텔레메트리, 자동 업데이트** | **없음** |

- 토큰은 본인 머신에서 나가지 않습니다 (Anthropic 본체로만 전송).
- 권한 범위는 Claude Desktop/CLI가 이미 가지고 있는 것과 동일 (새로 권한이 생기지 않음).
- 본 코드는 MIT 라이선스로 공개되어 누구든 감사 가능.

권한이 의심스러우면 `Sources/ClaudeUsageBar/CredentialStore.swift` (Keychain 읽기) 와 `ClaudeUsageProbe.swift` (API 호출) 두 파일만 보면 전체가 다 들어있습니다.

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| `Keychain 항목을 찾을 수 없습니다` | Claude Desktop/CLI 미로그인 | `claude` 실행 후 로그인 또는 Claude Desktop 로그인 |
| 매 실행마다 Keychain 다이얼로그 | "허용"만 누름 (1회용) | "항상 허용" 선택 |
| 자주 rebuild 후 다이얼로그 다시 뜸 | ad-hoc 서명 사용 중 (해시 변동) | Apple Development 인증서 보유 시 자동 해결 / Keychain Access.app에서 ACL 수동 추가 |
| `HTTP 401` | OAuth 토큰 만료 | Claude Desktop 열어서 자동 갱신 트리거 |
| `HTTP 429` | Rate-limit | 갱신 주기를 늘리세요 (60분 권장) |
| 앱 2개가 실행되는데 메뉴바엔 안 보임 | macOS 26.0.x SwiftUI MenuBarExtra 회귀 의심 / App Translocation | `killall -9 ClaudeUsageBar` 후 `.app`을 `/Applications/`로 옮기고 `xattr -dr com.apple.quarantine ClaudeUsageBar.app` 후 재실행. 안 되면 26.1+로 OS 업데이트 |
| Gatekeeper "확인되지 않은 개발자" | dev cert 미보유 → ad-hoc 서명 | Finder에서 우클릭 → 열기 (한 번만), 이후엔 무음 동작 |

## 자동 실행 설정

`시스템 설정 → 일반 → 로그인 항목` 에서 `ClaudeUsageBar.app` 추가하면 부팅 시 자동 시작.

## 프로젝트 구조

```
ClaudeUsageBar/
├── Sources/ClaudeUsageBar/
│   ├── ClaudeUsageBarApp.swift   # @main + MenuBarExtra 진입점
│   ├── CredentialStore.swift     # Keychain 읽기 (Security framework)
│   ├── ClaudeUsageProbe.swift    # /api/oauth/usage HTTP 호출 + 파싱
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
