import Foundation

// 리뷰에서 나온 P2/P3 결함의 회귀 케이스. 실제 StatusProbe.parse 를 통과시킨다.

struct LogicTests {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ cond: Bool, _ label: String) {
        print(cond ? "  ✓ \(label)" : "  ✗ \(label)")
        if !cond { failures += 1 }
    }

    static func parse(_ json: String) -> StatusProbe.Snapshot {
        try! StatusProbe.parse(Data(json.utf8))
    }

    static func run() {
        print("\n=== 회귀 케이스 ===")

        // P2 — 미지 컴포넌트 상태가 가짜 장애를 만들면 안 된다 (forward-compat fail-soft)
        let unknownComp = parse("""
        {"status":{"indicator":"none","description":"All Systems Operational"},
         "components":[{"id":"a","name":"Claude Code","status":"operational","group":false},
                       {"id":"b","name":"Claude Cowork","status":"maintenance_scheduled","group":false}],
         "incidents":[],"scheduled_maintenances":[]}
        """)
        expect(unknownComp.components[1].status == .unknown, "미지 status → .unknown 폴백")
        expect(unknownComp.isHealthy, "미지 컴포넌트가 있어도 isHealthy (가짜 장애 금지)")
        expect(!unknownComp.hasOutage, "미지 컴포넌트로 메뉴바 경보 안 뜸")

        // P2 — 점검 중은 카드에는 뜨되 메뉴바 경보는 아니다
        let maint = parse("""
        {"status":{"indicator":"maintenance","description":"Scheduled Maintenance"},
         "components":[{"id":"a","name":"Claude Code","status":"under_maintenance","group":false},
                       {"id":"b","name":"claude.ai","status":"operational","group":false}],
         "incidents":[],"scheduled_maintenances":[]}
        """)
        expect(!maint.isHealthy, "점검 중이면 카드는 펼쳐짐(isHealthy=false)")
        expect(!maint.hasOutage, "점검 중은 메뉴바 경보 아님")
        expect(maint.degradedComponents.isEmpty, "점검 중은 degraded 아님")
        expect(maint.noteworthyComponents.count == 1, "점검 중은 noteworthy에 포함")

        // 실제 장애는 여전히 잡혀야 한다 (수정이 경보를 죽이지 않았는지)
        let outage = parse("""
        {"status":{"indicator":"major","description":"Partial System Outage"},
         "components":[{"id":"a","name":"Claude Code","status":"partial_outage","group":false}],
         "incidents":[{"id":"i","name":"Elevated errors","status":"investigating",
                       "impact":"major","shortlink":"https://stspg.io/abc"}],
         "scheduled_maintenances":[]}
        """)
        expect(!outage.isHealthy, "실제 장애 → isHealthy=false")
        expect(outage.hasOutage, "실제 장애 → 메뉴바 경보")
        expect(outage.degradedComponents.count == 1, "partial_outage는 degraded")
        expect(outage.incidents.first?.url != nil, "허용 호스트(stspg.io) https 링크는 통과")

        // indicator가 정상이어도 컴포넌트 장애면 경보
        let compOnly = parse("""
        {"status":{"indicator":"none","description":"All Systems Operational"},
         "components":[{"id":"a","name":"Claude Code","status":"major_outage","group":false}],
         "incidents":[],"scheduled_maintenances":[]}
        """)
        expect(compOnly.hasOutage, "indicator=none이어도 컴포넌트 장애면 경보")

        // P2 — 원격 URL 스킴/호스트 검증
        let badURLs = parse("""
        {"status":{"indicator":"major","description":"x"},"components":[],
         "incidents":[{"id":"1","name":"smb","status":"investigating","impact":"major","shortlink":"smb://attacker.example/share"},
                      {"id":"2","name":"file","status":"investigating","impact":"major","shortlink":"file:///Applications/Calculator.app"},
                      {"id":"3","name":"http","status":"investigating","impact":"major","shortlink":"http://stspg.io/abc"},
                      {"id":"4","name":"evil-host","status":"investigating","impact":"major","shortlink":"https://evil.example/abc"},
                      {"id":"5","name":"lookalike","status":"investigating","impact":"major","shortlink":"https://stspg.io.evil.example/abc"},
                      {"id":"6","name":"ok","status":"investigating","impact":"major","shortlink":"https://status.claude.com/incidents/1"}],
         "scheduled_maintenances":[]}
        """)
        expect(badURLs.incidents[0].url == nil, "smb:// 차단")
        expect(badURLs.incidents[1].url == nil, "file:// 차단")
        expect(badURLs.incidents[2].url == nil, "http:// 차단 (https만)")
        expect(badURLs.incidents[3].url == nil, "미허용 호스트 차단")
        expect(badURLs.incidents[4].url == nil, "유사 호스트(stspg.io.evil.example) 차단")
        expect(badURLs.incidents[5].url != nil, "status.claude.com https 통과")

        // P3 — 예정된 점검이 진행 중처럼 잡히면 안 된다
        let sched = parse("""
        {"status":{"indicator":"none","description":"All Systems Operational"},
         "components":[{"id":"a","name":"Claude Code","status":"operational","group":false}],
         "incidents":[],
         "scheduled_maintenances":[{"id":"m1","name":"2주 뒤 점검","status":"scheduled","impact":"maintenance","shortlink":"https://stspg.io/m1"},
                                   {"id":"m2","name":"지금 점검 중","status":"in_progress","impact":"maintenance","shortlink":"https://stspg.io/m2"}]}
        """)
        expect(sched.maintenances.count == 1, "예정(scheduled) 점검은 제외, 진행 중만 1건")
        expect(sched.maintenances.first?.name == "지금 점검 중", "남은 것이 진행 중 건")

        // 그룹 헤더 제외
        let grouped = parse("""
        {"status":{"indicator":"none","description":"x"},
         "components":[{"id":"g","name":"그룹","status":"operational","group":true},
                       {"id":"a","name":"Claude Code","status":"operational","group":false}],
         "incidents":[],"scheduled_maintenances":[]}
        """)
        expect(grouped.components.count == 1, "그룹 헤더는 컴포넌트 목록에서 제외")

        // 실 페이로드가 여전히 파싱되는지 (DTO에 status 필드를 추가한 뒤 회귀 확인)
        if let live = FileManager.default.contents(atPath: "fixtures/summary-live.json") {
            let snap = try! StatusProbe.parse(live)
            expect(snap.components.count == 6, "실 페이로드 컴포넌트 6종 파싱")
            expect(snap.isHealthy, "실 페이로드(현재 전부 정상) → isHealthy")
            expect(!snap.hasOutage, "실 페이로드 → 경보 없음")
        } else {
            print("  · 실 페이로드 파일 없음 — 건너뜀")
        }

        runUsageAPICases()
        runLocalUsageCases()
        runCacheLayerCases()

        print(failures == 0 ? "\n✅ 회귀 케이스 전부 통과" : "\n❌ 실패 \(failures)건")
    }

    // MARK: - 사용량 API 파싱 (ClaudeUsageProbe)

    static func runUsageAPICases() {
        print("\n--- 사용량 API 파싱 ---")

        // 실 페이로드와 같은 형태(값만 합성값). 서버가 키를 늘려도 파싱이 견디는지.
        if let data = FileManager.default.contents(atPath: "fixtures/usage-live.json") {
            let snap = try! ClaudeUsageProbe.parseResponse(data, subscriptionType: "max")
            expect(snap.quotas.count == 3, "실 페이로드 limits 3건 파싱")
            expect(snap.session?.percentUsed == 42, "세션 % 파싱")
            expect(snap.quotas.contains { $0.scopeLabel == "Fable" }, "scope 모델 표시명 라벨")
            expect(snap.credits == nil, "크레딧 안 쓰는 계정은 표시 대상 아님(nil)")
            let fable = snap.quotas.first { $0.scopeLabel == "Fable" }
            expect(fable?.weeklyShare?.allowancePercent == 50 && fable?.weeklyShare?.usedPercent == 30,
                   "weekly_scoped_shares → 모델별 한도의 주간 대비 비중")
            expect(snap.activeQuota?.scopeLabel == "Fable", "is_active인 한도를 적용 중으로 뽑는다")
            expect(snap.session.map { MenuBarLabel.text(session: $0, active: snap.activeQuota) }
                   == "42% · Fable 60%", "메뉴바: 세션 외 한도가 걸려 있으면 함께 표시")
            expect(snap.session.map { MenuBarLabel.text(session: $0, active: $0) } == "42%",
                   "메뉴바: 세션이 적용 중이면 세션 %만")
            expect(snap.session.map { MenuBarLabel.text(session: $0, active: nil) } == "42%",
                   "메뉴바: 적용 중 한도 정보가 없으면 세션 %만")
        } else {
            print("  · fixtures/usage-live.json 없음 — 건너뜀")
        }

        // scope의 두 축(model / surface) + 라벨 없는 동종 limit 중복.
        // surface를 버리면 id가 kind만으로 만들어져 ForEach가 깨진다.
        let scoped = try! ClaudeUsageProbe.parseResponse(Data("""
        {"limits":[
          {"kind":"weekly_scoped","group":"weekly","percent":10,"severity":"normal","resets_at":null,
           "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false},
          {"kind":"weekly_scoped","group":"weekly","percent":20,"severity":"warning","resets_at":null,
           "scope":{"model":null,"surface":{"id":"cowork","display_name":"Cowork"}},"is_active":true},
          {"kind":"weekly_scoped","group":"weekly","percent":30,"severity":"normal","resets_at":null,
           "scope":null,"is_active":false},
          {"kind":"weekly_scoped","group":"weekly","percent":40,"severity":"normal","resets_at":null,
           "scope":null,"is_active":false}]}
        """.utf8), subscriptionType: nil)
        expect(scoped.quotas.count == 4, "동종 limit 4건 모두 파싱")
        expect(scoped.quotas.contains { $0.scopeLabel == "Cowork" }, "surface만 있는 limit도 라벨 유지")
        expect(Set(scoped.quotas.map(\.id)).count == 4, "id 중복 없음 (ForEach 렌더 붕괴 방지)")

        // 비중은 `limits`의 **원본 인덱스**로 붙는다. 앞의 limit이 파싱에서 탈락해도
        // (percent 없음) 밀려서 다른 한도에 붙으면 안 된다. 범위를 벗어난 값은 버린다.
        let shares = try! ClaudeUsageProbe.parseResponse(Data("""
        {"limits":[
          {"kind":"broken","group":"weekly"},
          {"kind":"weekly_all","group":"weekly","percent":50,"severity":"normal","scope":null,"is_active":true},
          {"kind":"weekly_scoped","group":"weekly","percent":59,"severity":"normal",
           "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false},
          {"kind":"weekly_scoped","group":"weekly","percent":5,"severity":"normal",
           "scope":{"model":{"id":null,"display_name":"Opus"},"surface":null},"is_active":false}],
         "weekly_scoped_shares":[
          {"limit_index":2,"used_percent_of_weekly":30,"allowance_percent_of_weekly":50},
          {"limit_index":3,"used_percent_of_weekly":5,"allowance_percent_of_weekly":250},
          {"limit_index":9,"used_percent_of_weekly":1,"allowance_percent_of_weekly":1}]}
        """.utf8), subscriptionType: nil)
        expect(shares.quotas.count == 3, "깨진 limit 1건은 탈락")
        expect(shares.quotas.first { $0.kind == "weekly_all" }?.weeklyShare == nil,
               "탈락한 limit 때문에 비중이 앞 한도로 밀리지 않는다")
        expect(shares.quotas.first { $0.scopeLabel == "Fable" }?.weeklyShare?.allowancePercent == 50,
               "비중은 원본 인덱스의 한도에 붙는다")
        expect(shares.quotas.first { $0.scopeLabel == "Opus" }?.weeklyShare == nil,
               "0~100을 벗어난 비중은 표시하지 않는다")
        // 세션과 다른 한도가 동시에 active면 세션이 아닌 쪽(그중 가장 많이 찬 것)을 고른다.
        let multi = try! ClaudeUsageProbe.parseResponse(Data("""
        {"limits":[
          {"kind":"session","group":"session","percent":20,"severity":"normal","scope":null,"is_active":true},
          {"kind":"weekly_all","group":"weekly","percent":50,"severity":"normal","scope":null,"is_active":true},
          {"kind":"weekly_scoped","group":"weekly","percent":95,"severity":"critical",
           "scope":{"model":{"id":"tangelo","display_name":null},"surface":null},"is_active":true}]}
        """.utf8), subscriptionType: nil)
        expect(multi.activeQuota?.percentUsed == 95, "복수 active → 세션이 아닌 쪽 중 최댓값")
        expect(multi.session.map { MenuBarLabel.text(session: $0, active: multi.activeQuota) }
               == "20% · 주간 모델 95%", "표시명 없는 모델별 한도는 '주간'으로 뭉개지 않는다")
        expect(MenuBarLabel.text(session: multi.quotas[0], active: multi.quotas[1]) == "20% · 주간 50%",
               "주간 전체가 적용 중이면 '주간'")
        expect(MenuBarLabel.text(session: shares.quotas[0], active: shares.quotas[0]) == "50%"
               && shares.activeQuota?.kind == "weekly_all", "주간 전체가 적용 중인 경우")

        // 크레딧: spend + extra_usage → 표시용 요약
        let paid = try! ClaudeUsageProbe.parseResponse(Data("""
        {"limits":[{"kind":"session","group":"session","percent":5,"severity":"normal",
                    "resets_at":null,"scope":null,"is_active":true}],
         "extra_usage":{"is_enabled":true,"spend_limit_reached":true,"utilization":80},
         "spend":{"enabled":true,"percent":80,"severity":"warning",
                  "used":{"amount_minor":1234,"currency":"USD","exponent":2},
                  "limit":{"amount_minor":5000,"currency":"USD","exponent":2}}}
        """.utf8), subscriptionType: nil)
        expect(paid.credits != nil, "크레딧 사용 계정은 요약 생성")
        expect(near(paid.credits?.used?.amount ?? 0, 12.34), "minor unit + exponent → 12.34")
        expect(near(paid.credits?.limit?.amount ?? 0, 50), "한도 금액 50.00")
        expect(paid.credits?.percent == 80, "percent 반영")
        expect(paid.credits?.limitReached == true, "spend_limit_reached 반영")
        expect(paid.credits?.severity == .warning, "severity 반영")

        // 단위를 모르는 금액 형태는 표시하지 않는다(추측 금지)
        let vague = try! ClaudeUsageProbe.parseResponse(Data("""
        {"limits":[{"kind":"session","group":"session","percent":5,"severity":"normal",
                    "resets_at":null,"scope":null,"is_active":true}],
         "extra_usage":{"is_enabled":true},"spend":{"enabled":true,"used":30}}
        """.utf8), subscriptionType: nil)
        expect(vague.credits != nil, "켜져 있으면 요약은 생성")
        expect(vague.credits?.used == nil, "형태 미상 금액은 nil (잘못된 금액 표시 금지)")

        // 크레딧 percent는 **켜져 있는 쪽**에서 온다. 서버가 꺼진 spend에도 `percent: 0`,
        // `used: 0`을 채워 보내기 때문에 단순 `??` 폴백은 extra_usage를 영원히 가린다.
        let extraOnly = try! ClaudeUsageProbe.parseResponse(Data("""
        {"limits":[{"kind":"session","group":"session","percent":5,"severity":"normal",
                    "resets_at":null,"scope":null,"is_active":true}],
         "extra_usage":{"is_enabled":true,"utilization":85,"spend_limit_reached":false},
         "spend":{"enabled":false,"percent":0,"severity":"normal","limit":null,
                  "used":{"amount_minor":0,"currency":"USD","exponent":2}}}
        """.utf8), subscriptionType: nil)
        expect(extraOnly.credits?.percent == 85, "spend 꺼짐 + extra_usage 켜짐 → utilization 채택")
        expect(extraOnly.credits?.used == nil, "0원은 금액으로 표시하지 않는다(소진율을 가림)")

        let bothOn = try! ClaudeUsageProbe.parseResponse(Data("""
        {"limits":[{"kind":"session","group":"session","percent":5,"severity":"normal",
                    "resets_at":null,"scope":null,"is_active":true}],
         "extra_usage":{"is_enabled":true,"utilization":95},
         "spend":{"enabled":true,"percent":30,"severity":"normal","limit":null,
                  "used":{"amount_minor":300,"currency":"USD","exponent":2}}}
        """.utf8), subscriptionType: nil)
        expect(bothOn.credits?.percent == 30, "spend가 켜져 있으면 그쪽 percent가 우선")

        // exponent가 없으면 금액을 표시하지 않는다 — 2로 가정하면 JPY/KRW가 100배 축소된다.
        let noExponent = try! ClaudeUsageProbe.parseResponse(Data("""
        {"limits":[{"kind":"session","group":"session","percent":5,"severity":"normal",
                    "resets_at":null,"scope":null,"is_active":true}],
         "spend":{"enabled":true,"percent":10,"used":{"amount_minor":1500,"currency":"JPY"}}}
        """.utf8), subscriptionType: nil)
        expect(noExponent.credits?.used == nil, "exponent 없는 금액은 표시 안 함")

        // display_name 없는 scope 축: 라벨로 승격하면 내부 코드네임이 UI에 샌다.
        let codename = try! ClaudeUsageProbe.parseResponse(Data("""
        {"limits":[
          {"kind":"weekly_scoped","group":"weekly","percent":1,"severity":"normal","resets_at":null,
           "scope":{"model":{"id":"tangelo","display_name":null},"surface":null},"is_active":false},
          {"kind":"weekly_scoped","group":"weekly","percent":2,"severity":"normal","resets_at":null,
           "scope":{"model":{"id":"iguana_necktie","display_name":null},"surface":null},"is_active":false}]}
        """.utf8), subscriptionType: nil)
        expect(codename.quotas.allSatisfy { $0.scopeLabel == nil }, "내부 id는 표시 라벨로 승격하지 않음")
        expect(Set(codename.quotas.map(\.id)).count == 2, "라벨이 없어도 id는 코드네임으로 구분됨")

        // 레거시 폴백 — limits가 없을 때. utilization이 정수여도 받아야 한다.
        let legacy = try! ClaudeUsageProbe.parseResponse(Data("""
        {"five_hour":{"utilization":30},
         "seven_day":{"utilization":60.5},
         "seven_day_cowork":{"utilization":5}}
        """.utf8), subscriptionType: nil)
        expect(legacy.quotas.count == 3, "레거시 폴백 3건 (cowork 포함)")
        expect(legacy.session?.percentUsed == 30, "정수 utilization 파싱")
        expect(legacy.quotas.contains { $0.scopeLabel == "Cowork" }, "seven_day_cowork 매핑")
    }

    // MARK: - 로컬 사용량 단가·집계 (LocalUsageReader)

    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    private static func cost(_ model: String, _ t: LocalUsageReader.Tally, fast: Bool = false) -> Double {
        LocalUsageReader.estimatedCost(model: model, fast: fast, tally: t)
    }

    static func runLocalUsageCases() {
        print("\n--- 로컬 사용량 단가·집계 ---")

        // ① 단가. Opus 4.x 시대 값($15/$75)이 되살아나면 여기서 걸린다.
        expect(near(cost("claude-opus-5", .init(input: 1_000_000)), 5), "Opus 5 input $5/MTok")
        expect(near(cost("claude-opus-5", .init(output: 1_000_000)), 25), "Opus 5 output $25/MTok")
        expect(near(cost("claude-opus-4-20250514", .init(input: 1_000_000)), 15),
               "구세대 Opus(4.0/4.1/3)는 $15/MTok 유지")
        expect(near(cost("claude-fable-5", .init(input: 1_000_000)), 10),
               "Fable $10/MTok — sonnet 기본값으로 새지 않음")
        expect(near(cost("claude-sonnet-5", .init(input: 1_000_000)), 2), "Sonnet 5 $2/MTok")
        expect(near(cost("claude-sonnet-4-6", .init(input: 1_000_000)), 3), "Sonnet 4.x는 $3/MTok 유지")

        // 세대가 바뀌며 단가와 **캐시 읽기 배율**이 함께 내려왔다. 이 줄들이 빠지면
        // 직전 세대 단가로 계산돼 총액이 2배 넘게 부푼다(실측 2026-11).
        expect(near(cost("claude-opus-5-5", .init(input: 1_000_000)), 4), "Opus 5.5 input $4/MTok")
        expect(near(cost("claude-opus-5-5", .init(output: 1_000_000)), 20), "Opus 5.5 output $20/MTok")
        expect(near(cost("claude-opus-5-5", .init(cacheRead: 1_000_000)), 0.2), "Opus 5.5 캐시 read $0.20 (0.05x)")
        expect(near(cost("claude-opus-5-5", .init(output: 1_000_000), fast: true), 40), "Opus 5.5 fast $40/MTok")
        expect(near(cost("claude-fable-5-2", .init(input: 1_000_000)), 8), "Fable 5.2 input $8/MTok")
        expect(near(cost("claude-fable-5-2", .init(cacheRead: 1_000_000)), 0.2), "Fable 5.2 캐시 read $0.20 (0.025x)")
        expect(near(cost("claude-fable-5-2", .init(cacheWrite1h: 1_000_000)), 16), "Fable 5.2 1h 캐시 write $16")
        expect(near(cost("claude-mythos-5-2", .init(output: 1_000_000)), 40), "Mythos 5.2는 Fable 5.2와 같은 단가")
        expect(near(cost("claude-fable-5-1", .init(cacheRead: 1_000_000)), 0.25), "Fable 5.1 캐시 read $0.25 (0.025x)")
        expect(near(cost("claude-fable-5", .init(cacheRead: 1_000_000)), 1), "Fable 5 캐시 read $1 (0.1x)")
        expect(near(cost("claude-fable-5-20260601", .init(input: 1_000_000)), 10),
               "날짜 접미사가 버전 마커(-5-2)에 걸리지 않는다")
        expect(near(cost("claude-sonnet-5-5", .init(cacheRead: 1_000_000)), 0.1), "Sonnet 5.5 캐시 read $0.10 (0.05x)")
        expect(near(cost("claude-haiku-5-5", .init(output: 1_000_000)), 0.5), "Haiku 5.5 output $0.50/MTok")
        let parts = LocalUsageReader.costParts(
            model: "claude-opus-5-5", fast: false,
            tally: .init(input: 1_000_000, output: 1_000_000, cacheWrite5m: 1_000_000, cacheRead: 1_000_000))
        expect(near(parts.inputOutput, 24) && near(parts.cacheWrite, 5) && near(parts.cacheRead, 0.2),
               "금액 내역: 입출력 / 캐시 쓰기 / 캐시 읽기로 분해")
        expect(near(cost("claude-haiku-4-5", .init(input: 1_000_000)), 1), "Haiku 4.5 $1/MTok")
        expect(near(cost("claude-opus-5", .init(output: 1_000_000), fast: true), 50),
               "fast mode는 프리미엄 단가($50/MTok)")
        expect(near(cost("claude-opus-4-20250514", .init(output: 1_000_000), fast: true), 150),
               "구세대 Opus + fast는 단가가 내려가지 않는다(base×2)")
        expect(near(cost("claude-sonnet-5", .init(output: 1_000_000), fast: true), 20),
               "비-Opus에 fast가 붙어도 프리미엄이 누락되지 않는다")

        // 캐시 배율 — 1h를 5m으로 뭉개면 여기서 걸린다.
        expect(near(cost("claude-opus-5", .init(cacheWrite5m: 1_000_000)), 6.25), "5m 캐시 write = base×1.25")
        expect(near(cost("claude-opus-5", .init(cacheWrite1h: 1_000_000)), 10), "1h 캐시 write = base×2")
        expect(near(cost("claude-opus-5", .init(cacheRead: 1_000_000)), 0.5), "캐시 read = base×0.1")

        // ② 로그 집계 — 실제 파서 경로에 픽스처 파일을 통과시킨다.
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cub-verify-\(UUID().uuidString)", isDirectory: true)
        let subDir = tmp.appendingPathComponent("sess/subagents", isDirectory: true)
        try? fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let mainURL = tmp.appendingPathComponent("sess.jsonl")
        let subURL = subDir.appendingPathComponent("agent-1.jsonl")
        try? logFixtureMain.write(to: mainURL, atomically: true, encoding: .utf8)
        try? logFixtureSubagent.write(to: subURL, atomically: true, encoding: .utf8)

        guard let mainEntry = LocalUsageReader.parse(fileAt: mainURL),
              let subEntry = LocalUsageReader.parse(fileAt: subURL) else {
            expect(false, "픽스처 로그 파싱 실패")
            return
        }
        let days = LocalUsageReader.buckets(from: [mainEntry, subEntry])
        expect(days.count == 1, "같은 시각의 로그는 한 버킷으로 합산 — 현재 \(days.count)건")
        guard let day = days.first else { return }

        // msg_A는 content block 3줄로 기록됐지만 usage는 한 번만 세야 한다(실측 2.6배 과대 결함).
        expect(day.interactive.output == 1_300, "message.id 중복 제거 (A 3줄 → 1회)")
        expect(day.interactive.input == 30, "input 합산")
        expect(day.interactive.cacheWrite1h == 1_000, "1h 캐시 write 분리 집계")
        expect(day.interactive.cacheWrite5m == 2_500,
               "5m 집계 + `cache_creation` 없는 구 로그는 5m으로 폴백")
        expect(day.interactive.cacheWrite == 3_500, "cacheWrite는 TTL 합계")
        expect(day.interactive.cacheRead == 11_000, "캐시 read 합산")
        expect(day.automation.output == 999, "/subagents/ 경로는 자동화로 분류")

        let expected =
            cost("claude-opus-5", .init(input: 10, output: 100, cacheWrite1h: 1_000, cacheRead: 5_000))
          + cost("claude-fable-5", .init(input: 20, output: 200, cacheWrite5m: 2_000, cacheRead: 6_000))
          + cost("claude-opus-5", .init(cacheWrite5m: 500))
          + cost("claude-opus-5", .init(output: 1_000), fast: true)
        expect(near(day.interactiveCost, expected),
               "비용은 모델·TTL·speed별 단가로 합산 (기대 \(expected), 실제 \(day.interactiveCost))")
        expect(day.automationCost > 0, "자동화 비용도 집계")
        expect(abs(day.costParts.total - day.totalCost) < 1e-9, "내역 합계 = 총 비용")
    }

    /// 캐시 계층(버전 폐기 · mtime 스킵 · 프루닝 · 파생값 미저장 · 파일 권한)을
    /// **실제 `scan()`**으로 잰다. 파서만 열어두면 이 계층에 회귀 가드가 0건이 된다.
    static func runCacheLayerCases() {
        print("\n--- 로컬 사용량 캐시 계층 ---")
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cub-cache-\(UUID().uuidString)", isDirectory: true)
        let root = tmp.appendingPathComponent("projects", isDirectory: true)
        let cacheURL = tmp.appendingPathComponent("cache/usage-cache.json")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        func mtime(_ url: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        func scan() -> LocalUsageReader.Data {
            LocalUsageReader.scan(windowDays: 3_650, root: root, cacheURL: cacheURL)
        }

        let logURL = root.appendingPathComponent("sess.jsonl")
        try? logFixtureMain.write(to: logURL, atomically: true, encoding: .utf8)
        let first = scan()
        expect(first.days.count == 1, "scan()이 주입된 root를 읽는다 — 현재 \(first.days.count)건")
        let baseline = first.days.first?.interactiveCost ?? 0
        expect(baseline > 0, "비용 산출")

        // 단가는 **읽을 때** 환산해야 한다. 비용을 캐시에 굳히면 단가표를 고쳐도
        // mtime이 그대로인 과거 로그는 구 단가 값을 계속 반환한다.
        let rawCache = (try? String(contentsOf: cacheURL, encoding: .utf8)) ?? ""
        expect(!rawCache.contains("iCost") && !rawCache.contains("aCost"),
               "캐시에 비용(파생값)을 저장하지 않는다")
        expect(rawCache.contains("\"0|claude-opus-5\""), "모델·speed 키로 토큰을 저장한다")
        let perms = ((try? fm.attributesOfItem(atPath: cacheURL.path))?[.posixPermissions]
                     as? NSNumber)?.intValue
        expect(perms == 0o600,
               "캐시 파일 0600 (프로젝트 경로가 키다) — 현재 \(perms.map { String($0, radix: 8) } ?? "없음")")

        // mtime이 그대로면 내용이 바뀌어도 재파싱하지 않는다(스킵 경로).
        let stamp = mtime(logURL)
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        if let stamp { try? fm.setAttributes([.modificationDate: stamp], ofItemAtPath: logURL.path) }
        // 비용 비교는 허용오차로 한다 — `cost(of:)`가 모델별 딕셔너리를 순회해 합산하므로
        // 합산 순서가 실행마다 달라 마지막 비트가 흔들린다(표시에는 무관).
        let reuse = scan()
        expect(near(reuse.days.first?.interactiveCost ?? -1, baseline),
               "mtime 동일 → 캐시 재사용 (기준 \(baseline), 실제 \(reuse.days.first?.interactiveCost ?? -1))")

        // mtime이 바뀌면 재파싱한다(내용이 비었으니 0건이 되어야 한다).
        // 허용치가 0.5초라 `Date()`로는 부족하다 — 테스트가 그보다 빨리 돌아 캐시에 맞는다.
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)],
                              ofItemAtPath: logURL.path)
        expect(scan().days.isEmpty, "mtime 변경 → 재파싱")

        // 버전이 다른 캐시는 통째로 버린다. 파일 mtime은 캐시 항목과 일치시켜 두고
        // 내용만 비우므로, 재파싱이 일어났다면 그것은 버전 폐기 때문이다.
        try? logFixtureMain.write(to: logURL, atomically: true, encoding: .utf8)
        _ = scan()
        let stamp2 = mtime(logURL)
        let stale = ((try? String(contentsOf: cacheURL, encoding: .utf8)) ?? "")
            .replacingOccurrences(of: "\"version\":5", with: "\"version\":1")
        try? stale.write(to: cacheURL, atomically: true, encoding: .utf8)
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        if let stamp2 { try? fm.setAttributes([.modificationDate: stamp2], ofItemAtPath: logURL.path) }
        expect(scan().days.isEmpty, "구 버전 캐시는 폐기되고 재파싱된다")

        // 윈도우 밖으로 나간 파일은 캐시에서 정리된다(무한 성장 방지).
        try? logFixtureMain.write(to: logURL, atomically: true, encoding: .utf8)
        _ = scan()
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400 * 30)],
                              ofItemAtPath: logURL.path)
        _ = LocalUsageReader.scan(windowDays: 1, root: root, cacheURL: cacheURL)
        let pruned = (try? String(contentsOf: cacheURL, encoding: .utf8)) ?? ""
        expect(!pruned.contains("sess.jsonl"), "윈도우 밖 파일은 캐시에서 프루닝")
        expect(stale.contains("\"version\":1"), "버전 폐기 검사가 실제로 캐시 버전을 바꿨다")

        // 파일 간 중복 — 세션을 이어가면 이전 메시지가 새 파일에 복제된다.
        // a.jsonl 원본 + b.jsonl(원본 전체 복사 + 새 메시지 1건) → 복사분은 한 번만.
        try? fm.removeItem(at: logURL)
        try? fm.removeItem(at: cacheURL)
        let aURL = root.appendingPathComponent("a.jsonl")
        let bURL = root.appendingPathComponent("b.jsonl")
        let extra = """
        {"type":"assistant","timestamp":"2026-08-20T04:00:00.000Z","entrypoint":"claude-desktop","message":{"id":"msg_NEW","model":"claude-opus-5","usage":{"input_tokens":0,"output_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        try? logFixtureMain.write(to: aURL, atomically: true, encoding: .utf8)
        try? (logFixtureMain + "\n" + extra).write(to: bURL, atomically: true, encoding: .utf8)
        let deduped = scan()
        expect(deduped.days.first?.interactive.output == 1_307,
               "파일 간 복제 메시지는 한 번만 (1,300 + 새 7) — 현재 \(deduped.days.first?.interactive.output ?? -1)")
        expect(scan().days.first?.interactive.output == 1_307, "캐시 재사용 경로에서도 같은 값")

        // 원본이 사라지면 복사본이 그 메시지의 유일한 소유자가 된다(값이 0으로 꺼지면 안 됨).
        try? fm.removeItem(at: aURL)
        expect(scan().days.first?.interactive.output == 1_307, "원본 삭제 → 남은 파일이 전량 소유")

        // 반대로 원본이 다시 나타나면 복사본은 다시 겹치는 몫을 내놓는다.
        try? logFixtureMain.write(to: aURL, atomically: true, encoding: .utf8)
        expect(scan().days.first?.interactive.output == 1_307, "원본 재등장 → 다시 한 번만")
    }

    /// 실제 로그 형태를 줄인 픽스처. A는 content block 3줄 복제, D는 `cache_creation`이
    /// 없던 구 형태, E는 fast mode, `<synthetic>`은 usage 0인 시스템 라인.
    private static let logFixtureMain = """
    {"type":"assistant","timestamp":"2026-08-20T04:00:00.000Z","entrypoint":"claude-desktop","message":{"id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100,"cache_creation_input_tokens":1000,"cache_read_input_tokens":5000,"cache_creation":{"ephemeral_1h_input_tokens":1000,"ephemeral_5m_input_tokens":0},"speed":"standard"}}}
    {"type":"assistant","timestamp":"2026-08-20T04:00:00.000Z","entrypoint":"claude-desktop","message":{"id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100,"cache_creation_input_tokens":1000,"cache_read_input_tokens":5000,"cache_creation":{"ephemeral_1h_input_tokens":1000,"ephemeral_5m_input_tokens":0},"speed":"standard"}}}
    {"type":"assistant","timestamp":"2026-08-20T04:00:00.000Z","entrypoint":"claude-desktop","message":{"id":"msg_A","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100,"cache_creation_input_tokens":1000,"cache_read_input_tokens":5000,"cache_creation":{"ephemeral_1h_input_tokens":1000,"ephemeral_5m_input_tokens":0},"speed":"standard"}}}
    {"type":"assistant","timestamp":"2026-08-20T04:00:00.000Z","entrypoint":"claude-desktop","message":{"id":"msg_B","model":"claude-fable-5","usage":{"input_tokens":20,"output_tokens":200,"cache_creation_input_tokens":2000,"cache_read_input_tokens":6000,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":2000},"speed":"standard"}}}
    {"type":"assistant","timestamp":"2026-08-20T04:00:00.000Z","entrypoint":"claude-desktop","message":{"id":"msg_D","model":"claude-opus-5","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":500,"cache_read_input_tokens":0}}}
    {"type":"assistant","timestamp":"2026-08-20T04:00:00.000Z","entrypoint":"claude-desktop","message":{"id":"msg_E","model":"claude-opus-5","usage":{"input_tokens":0,"output_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"speed":"fast"}}}
    {"type":"assistant","timestamp":"2026-08-20T04:00:00.000Z","entrypoint":"claude-desktop","message":{"id":"msg_S","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
    {"type":"user","timestamp":"2026-08-20T04:00:00.000Z","entrypoint":"claude-desktop","message":{"role":"user","content":"무시돼야 하는 라인"}}
    """

    /// 서브에이전트 로그. `entrypoint`가 부모 세션 값(claude-desktop)을 물려받으므로
    /// **경로**로 자동화를 판정해야 한다는 것이 이 픽스처의 요점이다.
    private static let logFixtureSubagent = """
    {"type":"assistant","timestamp":"2026-08-20T04:00:00.000Z","entrypoint":"claude-desktop","message":{"id":"msg_C","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":999,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"speed":"standard"}}}
    """
}
