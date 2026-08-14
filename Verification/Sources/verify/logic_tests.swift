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

        print(failures == 0 ? "\n✅ 회귀 케이스 전부 통과" : "\n❌ 실패 \(failures)건")
    }
}
