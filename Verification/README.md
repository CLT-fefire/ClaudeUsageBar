# Verification — 검증 하네스

앱 소스를 **심볼릭 링크로 그대로 컴파일**해서 ⓐ 도메인 로직 회귀 케이스와 ⓑ SwiftUI 뷰
오프스크린 렌더를 돌린다. 사본을 검증하면 실제 코드를 검증한 게 아니므로 링크를 쓴다.

```bash
cd Verification && swift run verify
```

- **회귀 케이스** (`logic_tests.swift`) — 실제 파서에 픽스처를 통과시켜 판정을 검사한다.
  통과하면 `✅`, 실패하면 exit 1. 세 갈래다:
  - `StatusProbe.parse` — 서비스 상태 판정(가짜 장애·URL 스킴·예정 점검).
  - `ClaudeUsageProbe.parseResponse` — `limits[]`의 scope 두 축(model/surface), id 유일성,
    `spend`/`extra_usage` → 크레딧 요약, 레거시 폴백. 픽스처 `fixtures/usage-live.json`은
    실 응답과 **같은 형태**(코드네임 키 포함)에 값만 합성값으로 바꾼 것이다.
  - `LocalUsageReader` — 모델·세대별 단가, 캐시 배율(write 5m 1.25x / 1h 2x, read는 세대별 0.1x·0.05x·0.025x), 파일 간 `message.id` 중복 제거,
    fast mode 프리미엄, `message.id` 중복 제거, `/subagents/` 자동화 분류. 로그 픽스처는
    임시 디렉토리에 써서 `parse(fileAt:)`(= 앱과 같은 `parseFile` 경로)로 통과시킨다.
  - **캐시 계층** — `scan(root:cacheURL:)`에 임시 디렉토리를 주입해 버전 폐기·mtime
    스킵·프루닝·파일 권한(0600)·파생값 미저장을 실측한다. 파서만 열어두면 이 계층에
    가드가 0건이 된다. ⚠️ mtime 허용치가 0.5초라 "변경"을 만들려면 초 단위로 벌려야 하고,
    비용 비교는 허용오차로 해야 한다(딕셔너리 합산 순서가 마지막 비트를 흔든다).
- **렌더 스냅샷** (`main.swift`) — `ImageRenderer`로 `shots/*.png` 생성. 팝오버는
  `MenuBarExtra`라 클릭으로 열 수 없고(Accessibility 권한 필요) 이것이 유일한 육안 검수 경로다.
  유리 테마는 `glassEffect`가 뒤 콘텐츠 굴절에 의존해 오프스크린에선 밋밋하게 나온다 —
  **레이아웃 검증은 불투명 테마로** 하고 유리 질감은 실기 확인에 맡긴다.

## 왜 별도 패키지인가

앱 타겟이 `@main` executable이라 `testTarget`에서 import할 수 없다. 라이브러리로 쪼개는
리팩터링 대신, 링크로 같은 소스를 컴파일하는 두 번째 패키지를 뒀다.

## 이 하네스가 잡은 것 (v0.12.0)

리뷰 게이트 BLOCK(0.72) 후 수정분의 회귀 케이스 24건이 여기 있다 — 미지 컴포넌트 상태가
가짜 장애를 만들던 문제, 원격 URL 스킴 검증(`smb://`·`file://`·유사 호스트 차단),
예정된 점검이 진행 중으로 잡히던 문제. 상세: `knowledge/claude-usage-bar/STATE.md`.

## 이 하네스가 잡는 것 (v0.13.0 추가)

단가·스키마·캐시 회귀 55건. 리뷰 게이트 BLOCK(0.73) 수정분까지 포함한다. 변이 11종을
일부러 넣어 각각 실패하는 것을 확인했다 — Opus 단가를 $15/$75로 되돌림 / 1h 배율을 5m과
동일하게 / `scope.surface` 무시 / `message.id` dedup 제거 / percent를 단순 `??` 폴백으로
되돌림 / scope `id`를 표시 라벨로 승격 / `exponent` 기본값 2 부활 / fast를 세대 판정보다
먼저 return / 캐시 버전 검사 무력화 / 캐시 파일 권한 지정 제거 / 비용을 캐시에 굳힘.
통과만 확인하고 넘어가면 아무것도 재지 않는 검사가 남는다.

## 자동화하지 않은 불변식 (체크리스트)

아래는 `UsageMonitor`가 `@MainActor` ObservableObject이면서 init에서 실제 폴링을 시작해
DI 이음매가 없는 탓에 단위 테스트로 옮기지 않았다. 억지 테스트화 대신 체크리스트로 둔다 —
**`UsageMonitor`의 비동기 경로를 고칠 때 이 항목을 먼저 읽을 것.**

- [ ] **비동기 갱신은 `Task` 취소 기반 last-wins로 쓴다.** `refreshStatus()`처럼
      진입 시 `statusTask?.cancel()` 후 새 Task를 할당하고, `await` 재개 뒤
      `guard !Task.isCancelled, isStatusEnabled` 로 확인한 다음에만 상태를 쓴다.
      (URLSession은 취소 시 `CancellationError`가 아니라 `URLError(.cancelled)`를
      던지므로 성공 경로에서도 `Task.isCancelled`를 직접 봐야 한다.)
- [ ] **불린 플래그 + 세대 카운터로 되돌리지 말 것.** v0.12.0에서 두 번 시도했다가
      두 번 다 깨졌다 — 가드 소유권이 `refreshStatus`의 `defer`와 `setStatusEnabled`
      양쪽으로 쪼개지면서, 폐기된 옛 태스크의 `defer`가 **현재 태스크가 살아있는 채로**
      가드를 풀어 동시 2요청 + out-of-order 덮어쓰기가 재발했다(진행 중 장애가 화면에서
      사라짐). 소유권이 Task 하나에 모여야 이 계열이 구조적으로 성립하지 않는다.
- [ ] **상태 폴링을 제어하는 UI는 인증·미인증 화면 양쪽에 있어야 한다.** 폴링 자체가
      인증과 무관하게 돌기 때문이다. 한쪽에만 두면 그 화면에 못 가는 상태에서 제어 불능이 된다.
- [ ] **크레딧 행(`creditsRow`)은 눈으로 확인해야 한다.** `MenuContentView`가 하네스에
      링크돼 있지 않아(`UsageMonitor`·`@AppStorage` 의존) 렌더 검증 대상이 아니다. 파서 쪽
      (`Credits` 생성/nil 판정)은 회귀 케이스가 덮지만, **줄바꿈·정렬은 크레딧을 켠 계정에서
      실기 확인**해야 한다. 크레딧을 안 쓰는 계정에서는 행 자체가 나타나지 않는 것이 정상이다.
- [ ] **회귀 가드는 앱 소스를 재야 한다.** 하네스 안에 사본 뷰를 만들어 그것을 검사하면
      앱이 망가져도 영원히 통과한다(v0.12.0 4차 리뷰 지적). 새 뷰를 검사 대상으로 넣을
      땐 `Sources/verify/`에 **심볼릭 링크**를 추가하고, 일부러 망가뜨려 검사가 실제로
      실패하는지 확인한 뒤 되돌린다. `MenuBarLabel`이 그렇게 검증됐다.

## 새 케이스 추가

`logic_tests.swift`의 `run()`에 `expect(조건, "설명")`을 추가한다. 픽스처는
`fixtures/`에 두고 실행 시 `../fixtures/`로 참조한다(작업 디렉토리가 `Verification/`).
