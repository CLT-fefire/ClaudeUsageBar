import Foundation

/// `~/.claude/projects/**/*.jsonl` (Claude Code 세션 로그)를 읽어
/// 날짜별 토큰·추정 비용을 **출처별**(대화형 vs 자동화)로 집계한다.
///
/// - 공식 사용량 API(%)와는 완전히 별개인 **로컬 추정치**다.
/// - 토큰은 input + output + cache write/read를 **모두** 합산한다.
///   (output만 세면 실제 소비량의 1% 미만만 보인다.)
/// - 출처 구분 기준:
///   - `/subagents/` 경로 → 자동화 (Task 에이전트·워크플로우 실행. 이 파일들의
///     `entrypoint`는 부모 세션 값을 그대로 물려받아 식별자로 쓸 수 없다.)
///   - `entrypoint == sdk-cli` → 자동화(headless: Agent SDK, `claude -p` 등)
///   - 그 외(`claude-desktop` / `claude-vscode` / `cli` …) → 대화형
///   (`promptSource`는 전송 방식일 뿐 대화형까지 sdk로 찍혀 식별자로 쓸 수 없음)
/// - **중복 제거 필수**: 하나의 assistant 메시지는 content block(text/tool_use) 수만큼
///   별도 라인으로 기록되고 각 라인이 동일한 usage 전체값을 복제한다. `message.id`
///   기준으로 첫 라인만 집계하지 않으면 블록 수만큼 곱해진다(실측 2.6배 과대).
///   세션을 이어가거나 분기하면 이전 메시지가 **새 로그 파일에도 복제**되므로 파일
///   경계를 넘어서도 같은 id를 한 번만 센다(2026-11 표본에서 190일 토큰의 약 12%가 이 복제분).
/// - 비용은 모델 단가 하드코딩 기반 **추정**이며 캐시 토큰까지 포함한다. 캐시 write는
///   TTL(5m/1h)별 단가가 다르고, 캐시 read 배율은 모델 세대별로 다르며,
///   `usage.speed == "fast"`는 프리미엄 단가라 셋 다 반영한다.
///   구독 요금이 아니라 **같은 사용량을 API 단가로 환산하면 얼마인지**를 보여주는 값이다.
enum LocalUsageReader {

    enum Source { case interactive, automation }

    /// 토큰 내역. `total`이 차트에 쓰는 실사용량.
    ///
    /// 캐시 write를 TTL별로 쪼개 담는다 — 단가가 다르다. 5분 TTL은 base input의
    /// 1.25배, 1시간 TTL은 2배다. 실측(2026-08) 로그에서 캐시 write의 73%가
    /// 1시간 TTL이라 합쳐서 1.25배로 계산하면 비용이 체계적으로 어긋난다.
    struct Tally: Sendable, Equatable, Codable {
        var input = 0
        var output = 0
        var cacheWrite5m = 0
        var cacheWrite1h = 0
        var cacheRead = 0

        /// 캐시 write 총합. 표시(차트·툴팁)에는 TTL 구분이 필요 없다.
        var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
        var total: Int { input + output + cacheWrite + cacheRead }

        static func += (lhs: inout Tally, rhs: Tally) {
            lhs.input += rhs.input; lhs.output += rhs.output
            lhs.cacheWrite5m += rhs.cacheWrite5m; lhs.cacheWrite1h += rhs.cacheWrite1h
            lhs.cacheRead += rhs.cacheRead
        }
    }

    /// 추정 비용을 성격별로 쪼갠 것. 캐시 읽기는 같은 컨텍스트를 매 턴 다시 보낸
    /// 반복분이라 금액의 과반을 차지한다 — 합계만 보여주면 "내가 쓴 양"과 어긋나 보여
    /// 툴팁에서 나눠 보여준다.
    struct CostParts: Sendable, Equatable {
        var inputOutput = 0.0
        var cacheWrite = 0.0
        var cacheRead = 0.0

        var total: Double { inputOutput + cacheWrite + cacheRead }

        static func += (lhs: inout CostParts, rhs: CostParts) {
            lhs.inputOutput += rhs.inputOutput
            lhs.cacheWrite += rhs.cacheWrite
            lhs.cacheRead += rhs.cacheRead
        }
    }

    /// 하루치 집계 (출처별 토큰 내역 + 추정 비용 USD).
    struct DayBucket: Sendable, Equatable, Identifiable {
        let day: Date          // 로컬 자정 기준 날짜
        let interactive: Tally
        let automation: Tally
        let interactiveCost: Double
        let automationCost: Double
        /// 두 출처를 합친 비용의 성격별 내역. `total`은 `totalCost`와 같다(허용오차 내).
        let costParts: CostParts

        var id: Date { day }
        var totalTokens: Int { interactive.total + automation.total }
        var totalOutput: Int { interactive.output + automation.output }
        var totalCost: Double { interactiveCost + automationCost }
    }

    struct Data: Sendable, Equatable {
        let days: [DayBucket]  // day 오름차순 정렬
        let capturedAt: Date
        static let empty = Data(days: [], capturedAt: .distantPast)
    }

    /// 기본 스캔 윈도우(일). 월 뷰 6개월(최대 ~184일)을 모두 커버하도록 여유 포함.
    static let defaultWindowDays = 190

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    static let defaultCacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/ClaudeUsageBar", isDirectory: true)
        .appendingPathComponent("usage-cache.json")

    /// 백그라운드에서 호출할 것. 파일 IO + JSON 파싱이 무겁다.
    ///
    /// `root`·`cacheURL`을 주입받는 이유는 검증 하네스가 **캐시 계층까지** 실측할 수
    /// 있어야 하기 때문이다. 파서만 열어두면 버전 폐기·mtime 스킵·프루닝에 회귀
    /// 가드가 0건인 채로 검사가 초록으로 뜬다(리뷰 P2).
    static func scan(windowDays: Int = defaultWindowDays,
                     root: URL = defaultRoot,
                     cacheURL: URL = defaultCacheURL) -> Data {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else {
            return .empty
        }

        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86_400)
        let (dayFmt, isoFrac, isoPlain) = makeFormatters()

        var cache = loadCache(from: cacheURL)
        var current: [String: FileEntry] = [:]

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  rv.isRegularFile == true,
                  let mtime = rv.contentModificationDate else { continue }
            if mtime < cutoff { continue }

            let path = url.path
            let mt = mtime.timeIntervalSince1970
            if let hit = cache.files[path], abs(hit.mtime - mt) < 0.5 {
                current[path] = hit  // 변경 없음 → 캐시 재사용
                continue
            }
            if let entry = parseFile(url, mtime: mt, dayFmt: dayFmt, isoFrac: isoFrac, isoPlain: isoPlain) {
                current[path] = entry
            }
        }

        resolveCrossFileDuplicates(&current, dayFmt: dayFmt, isoFrac: isoFrac, isoPlain: isoPlain)

        cache.files = current  // 윈도우 밖/삭제 파일은 자연 정리
        saveCache(cache, to: cacheURL)

        return Data(days: buckets(from: Array(current.values)), capturedAt: Date())
    }

    /// 날짜 키·ISO 타임스탬프 파서 묶음. `scan()`과 검증 진입점이 공유한다.
    /// (ISO8601DateFormatter가 Sendable이 아니라 static let 캐시는 못 쓴다.)
    private static func makeFormatters() -> (DateFormatter, ISO8601DateFormatter, ISO8601DateFormatter) {
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"
        dayFmt.calendar = Calendar.current
        dayFmt.timeZone = .current
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        return (dayFmt, isoFrac, isoPlain)
    }

    /// 파일별 일 집계를 날짜 기준으로 합산하고, **이 시점에** 단가를 적용한다.
    /// 검증 하네스가 부를 수 있도록 internal.
    static func buckets(from entries: [FileEntry]) -> [DayBucket] {
        let dayFmt = makeFormatters().0
        var merged: [String: DayAgg] = [:]
        for entry in entries {
            // 다른 파일과 겹치는 메시지가 있던 파일은 그 몫을 뺀 집계(`net`)를 쓴다.
            for (day, a) in entry.net?.days ?? entry.days {
                var m = merged[day] ?? DayAgg()
                DayAgg.merge(&m.i, a.i)
                DayAgg.merge(&m.a, a.a)
                merged[day] = m
            }
        }

        var out: [DayBucket] = []
        out.reserveCapacity(merged.count)
        for (day, m) in merged {
            guard let d = dayFmt.date(from: day) else { continue }
            let iCost = cost(of: m.i), aCost = cost(of: m.a)
            var parts = iCost
            parts += aCost
            out.append(DayBucket(
                day: d,
                interactive: sum(m.i), automation: sum(m.a),
                interactiveCost: iCost.total, automationCost: aCost.total,
                costParts: parts
            ))
        }
        out.sort { $0.day < $1.day }
        return out
    }

    private static func sum(_ tallies: [String: Tally]) -> Tally {
        tallies.values.reduce(into: Tally()) { $0 += $1 }
    }

    /// 모델별로 단가가 달라 합산 순서가 마지막 비트에 남는다(딕셔너리 순회 순서는
    /// 실행마다 다르다). 표시는 소수 1~2자리이므로 무해하지만, 비용을 비트 단위로
    /// 비교하는 검사를 쓰면 플레이키해진다 — 허용오차로 비교할 것.
    private static func cost(of tallies: [String: Tally]) -> CostParts {
        tallies.reduce(into: CostParts()) { total, entry in
            let (model, fast) = splitRateKey(entry.key)
            total += costParts(model: model, fast: fast, tally: entry.value)
        }
    }

    /// 단가를 좌우하는 것은 모델과 fast 여부뿐이므로 그 둘만 키로 삼는다.
    /// 모델 ID에 `|`가 들어가지 않아 첫 구분자로 안전하게 자를 수 있다.
    static func rateKey(model: String, fast: Bool) -> String { "\(fast ? 1 : 0)|\(model)" }

    private static func splitRateKey(_ key: String) -> (model: String, fast: Bool) {
        guard let sep = key.firstIndex(of: "|") else { return (key, false) }
        return (String(key[key.index(after: sep)...]), key[key.startIndex] == "1")
    }

    /// 파일 하나를 **실제 파서**에 통과시키는 검증 하네스용 진입점.
    /// 사본 파서를 만들면 앱이 망가져도 검사가 통과하므로 같은 경로를 쓴다.
    static func parse(fileAt url: URL) -> FileEntry? {
        let (dayFmt, isoFrac, isoPlain) = makeFormatters()
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        return parseFile(url, mtime: mtime, dayFmt: dayFmt, isoFrac: isoFrac, isoPlain: isoPlain)
    }

    // MARK: - 파일 파싱

    /// - Parameter excluding: **다른 파일이 이미 센** 메시지 id 해시. 여기 든 메시지는
    ///   집계에서 빼되 `ids`에는 남긴다(이 파일이 그 메시지를 담고 있다는 사실은 그대로다).
    private static func parseFile(
        _ url: URL, mtime: Double,
        dayFmt: DateFormatter, isoFrac: ISO8601DateFormatter, isoPlain: ISO8601DateFormatter,
        excluding: Set<UInt64> = []
    ) -> FileEntry? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        // 서브에이전트 로그는 entrypoint가 부모 세션 값이라 경로로 판정한다.
        let isSubagent = url.path.contains("/subagents/")

        var days: [String: DayAgg] = [:]
        var source: Source? = isSubagent ? .automation : nil
        var seenMessages = Set<UInt64>()   // content block 분할 라인 중복 제거
        var ids: [UInt64] = []             // 파일 간 중복 판정용(등장 순서)

        for sub in content.split(separator: "\n", omittingEmptySubsequences: true) {
            // 빠른 사전 필터: 관심 있는 라인만 JSON 파싱
            let isAsst = sub.contains("\"output_tokens\"")
            if !isAsst && !sub.contains("\"entrypoint\"") { continue }
            guard let data = sub.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if source == nil, let ep = obj["entrypoint"] as? String {
                source = (ep == "sdk-cli") ? .automation : .interactive
            }
            guard (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }

            // 같은 message.id의 두 번째 라인부터는 usage 복제본이므로 버린다.
            if let mid = msg["id"] as? String {
                let h = idHash(mid)
                guard seenMessages.insert(h).inserted else { continue }
                ids.append(h)
                if excluding.contains(h) { continue }
            }

            var t = Tally()
            t.input     = intValue(usage["input_tokens"])
            t.output    = intValue(usage["output_tokens"])
            t.cacheRead = intValue(usage["cache_read_input_tokens"])

            // 캐시 write는 TTL별 단가가 달라 `cache_creation` 하위 필드로 쪼갠다.
            // 구 로그엔 이 객체가 없고 서버가 TTL 버킷을 늘릴 수도 있으니 **1h만 신뢰하고
            // 나머지는 5m으로** 떨어뜨린다. top-level 합계가 더 크면 그쪽을 총량으로 본다.
            let cc = usage["cache_creation"] as? [String: Any]
            let write1h = intValue(cc?["ephemeral_1h_input_tokens"])
            let writeTotal = max(intValue(usage["cache_creation_input_tokens"]),
                                 write1h + intValue(cc?["ephemeral_5m_input_tokens"]))
            t.cacheWrite1h = min(write1h, writeTotal)
            t.cacheWrite5m = writeTotal - t.cacheWrite1h

            let model = (msg["model"] as? String) ?? ""
            // fast mode는 같은 모델을 프리미엄 단가로 돌린다. `usage.speed`가 유일한 단서다.
            let isFast = (usage["speed"] as? String) == "fast"
            guard let tsStr = obj["timestamp"] as? String,
                  let ts = isoFrac.date(from: tsStr) ?? isoPlain.date(from: tsStr) else { continue }

            let key = dayFmt.string(from: ts)
            let rk = rateKey(model: model, fast: isFast)

            var a = days[key] ?? DayAgg()
            if (source ?? .interactive) == .automation {
                var acc = a.a[rk] ?? Tally(); acc += t; a.a[rk] = acc
            } else {
                var acc = a.i[rk] ?? Tally(); acc += t; a.i[rk] = acc
            }
            days[key] = a
        }
        return FileEntry(mtime: mtime, days: days, ids: pack(ids))
    }

    // MARK: - 파일 간 중복 제거

    /// 세션을 이어가기(resume)·분기(fork)하면 Claude Code가 이전 대화의 라인을 새
    /// 세션 파일에 **그대로 복사**한다. `message.id`가 같으므로 파일 안에서만 dedup하면
    /// 복사본이 한 번씩 더 집계된다.
    ///
    /// 경로 사전순으로 훑어 **먼저 나온 파일이 그 메시지를 소유**한다. 어느 쪽이
    /// 소유하든 합계는 같다(복사본은 timestamp·usage까지 동일). 겹치는 메시지가 있는
    /// 파일만 그 id들을 빼고 다시 파싱해 `net`에 담는다 — 메시지별 내역을 캐시에 다
    /// 싣지 않기 위한 절충이다(11만 메시지 × 토큰 5종이면 캐시가 수 MB로 불어난다).
    ///
    /// `net`의 유효성은 **제외 건수**로 판정한다. 로그는 append-only라 한 파일의 id
    /// 집합은 늘기만 하고, 그 파일 자체가 바뀌면 mtime이 달라져 `net`이 통째로
    /// 재생성되므로 건수가 같으면 제외 집합도 같다.
    private static func resolveCrossFileDuplicates(
        _ entries: inout [String: FileEntry],
        dayFmt: DateFormatter, isoFrac: ISO8601DateFormatter, isoPlain: ISO8601DateFormatter
    ) {
        var owned = Set<UInt64>()
        for path in entries.keys.sorted() {
            guard var entry = entries[path] else { continue }
            let ids = unpack(entry.ids)
            let duplicated = ids.filter(owned.contains)
            if duplicated.isEmpty {
                if entry.net != nil { entry.net = nil; entries[path] = entry }
            } else if entry.net?.excluded != duplicated.count {
                // 재파싱 실패(파일이 그새 사라짐 등)면 중복 포함 집계를 그대로 둔다 —
                // 다음 스캔에서 다시 시도된다.
                if let net = parseFile(URL(fileURLWithPath: path), mtime: entry.mtime,
                                       dayFmt: dayFmt, isoFrac: isoFrac, isoPlain: isoPlain,
                                       excluding: Set(duplicated)) {
                    entry.net = FileEntry.Net(excluded: duplicated.count, days: net.days)
                    entries[path] = entry
                }
            }
            owned.formUnion(ids)
        }
    }

    /// FNV-1a 64비트. `Hasher`는 프로세스마다 시드가 달라 캐시에 저장할 수 없다.
    private static func idHash(_ id: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    /// 해시 배열 ↔ 바이트열. JSON에는 base64 한 덩어리로 들어가 숫자 배열보다 작고
    /// 디코딩도 빠르다.
    private static func pack(_ ids: [UInt64]) -> Foundation.Data {
        ids.withUnsafeBufferPointer { Foundation.Data(buffer: $0) }
    }

    private static func unpack(_ data: Foundation.Data) -> [UInt64] {
        let count = data.count / MemoryLayout<UInt64>.size
        return data.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self) }
        }
    }

    /// 로그는 외부 입력이다. `Int(Double)`은 범위를 벗어나면 **트랩(프로세스 종료)**
    /// 하므로 유한·비음수·Int 범위인 값만 받고 나머지는 0으로 떨군다.
    private static func intValue(_ v: Any?) -> Int {
        if let i = v as? Int { return max(0, i) }
        guard let d = v as? Double, d.isFinite, d >= 0, d < Double(Int.max) else { return 0 }
        return Int(d)
    }

    // MARK: - 모델 단가 (USD, 추정)

    /// 백만 토큰당 base 단가 + 캐시 읽기 배율. 캐시 **쓰기** 배율은 전 모델 공통이지만
    /// **읽기** 배율은 세대마다 다르다(0.1x → 0.05x → 0.025x). 로그 금액의 과반이 캐시
    /// 읽기라 이 배율 하나가 총액을 좌우한다.
    private struct Rate {
        let input, output: Double
        var read = 0.1
    }

    /// 캐시 쓰기 배율(공식) — base **input** 단가 기준.
    private static let write5mMultiplier = 1.25
    private static let write1hMultiplier = 2.0

    /// fast mode 프리미엄 배율. Opus 5.5 $8/$40, Opus 5 $10/$50, Fable 5.2 $16/$80 —
    /// 모두 base의 2배다.
    /// **base에 곱하는 방식**이라 세대 판정보다 먼저 return하지 않는다 — 구세대 Opus에
    /// fast가 붙어 단가가 오히려 내려가거나, 비-Opus fast가 프리미엄을 빠뜨리는
    /// 분기 순서 결함을 구조적으로 없앤다.
    private static let fastMultiplier = 2.0

    /// $15/$75 시절 Opus(4.1 / 4.0 / 3). 날짜 접미사가 붙은 구 ID
    /// ("claude-opus-4-20250514")도 있어 버전 비교 대신 구세대 마커를 열거한다.
    private static let legacyOpusMarkers = ["3-opus", "opus-4-0", "opus-4-1", "opus-4-20"]

    private static func rate(model: String, fast: Bool) -> Rate {
        let base = baseRate(model.lowercased())
        guard fast else { return base }
        return Rate(input: base.input * fastMultiplier, output: base.output * fastMultiplier,
                    read: base.read)
    }

    /// 2026-11 기준 공개 단가(백만 토큰당). **새 모델이 나오면 여기에 줄을 추가해야
    /// 한다** — 세대가 바뀔 때마다 단가와 캐시 읽기 배율이 함께 내려왔고(Opus 5.5,
    /// Fable 5.2), 표를 안 고치면 직전 세대 단가로 계산돼 총액이 2배 넘게 부푼다
    /// (2026-11: 표를 3개월 방치해 2.1배 과대였다). 미상 모델은 Sonnet 4.x 기준으로 둔다.
    ///
    /// Haiku 5.5는 프롬프트 10만 토큰 초과 시 $0.50/$2.50인데 메시지별 프롬프트 크기를
    /// 캐시에 싣지 않아 하위 구간 단가만 쓴다(실측 비중 0.03% 미만).
    private static func baseRate(_ m: String) -> Rate {
        if m.contains("fable") || m.contains("mythos") {
            if hasVersion(m, "-5-2") { return Rate(input: 8, output: 40, read: 0.025) }
            if hasVersion(m, "-5-1") { return Rate(input: 10, output: 50, read: 0.025) }
            return Rate(input: 10, output: 50)
        }
        if m.contains("opus") {
            if legacyOpusMarkers.contains(where: m.contains) { return Rate(input: 15, output: 75) }
            if hasVersion(m, "opus-5-5") { return Rate(input: 4, output: 20, read: 0.05) }
            return Rate(input: 5, output: 25)
        }
        if m.contains("haiku") {
            return hasVersion(m, "haiku-5-5") ? Rate(input: 0.1, output: 0.5) : Rate(input: 1, output: 5)
        }
        if hasVersion(m, "sonnet-5-5") { return Rate(input: 2, output: 10, read: 0.05) }
        if hasVersion(m, "sonnet-5") { return Rate(input: 2, output: 10) }
        return Rate(input: 3, output: 15)   // sonnet 4.x + 기본값
    }

    /// 버전 마커가 **숫자로 이어지지 않을 때만** 일치로 본다. 단순 `contains`면
    /// 날짜 접미사가 붙은 ID("claude-fable-5-20260601")가 "-5-2"에 걸려 다른 세대
    /// 단가를 받는다.
    private static func hasVersion(_ m: String, _ marker: String) -> Bool {
        guard let r = m.range(of: marker) else { return false }
        return r.upperBound == m.endIndex || !m[r.upperBound].isNumber
    }

    /// 한 메시지(또는 합산 Tally)의 추정 비용 USD.
    /// 검증 하네스가 단가 회귀를 직접 잴 수 있도록 internal.
    static func estimatedCost(model: String, fast: Bool, tally t: Tally) -> Double {
        costParts(model: model, fast: fast, tally: t).total
    }

    static func costParts(model: String, fast: Bool, tally t: Tally) -> CostParts {
        let r = rate(model: model, fast: fast)
        let inPerToken = r.input / 1e6
        return CostParts(
            inputOutput: Double(t.input) * inPerToken + Double(t.output) * r.output / 1e6,
            cacheWrite: Double(t.cacheWrite5m) * inPerToken * write5mMultiplier
                + Double(t.cacheWrite1h) * inPerToken * write1hMultiplier,
            cacheRead: Double(t.cacheRead) * inPerToken * r.read
        )
    }

    // MARK: - 캐시 (파일 mtime 기준 증분 파싱)

    /// 하루치 원자료 — **토큰만** 담는다. 비용은 `buckets(from:)`에서 환산한다.
    /// 파생값(비용)을 캐시에 굳히면 단가표를 고칠 때마다 `cacheVersion`을 손으로
    /// 올려야 하고, 잊으면 구 단가로 계산된 날과 새 단가로 계산된 날이 한 차트에
    /// 섞인다(리뷰 P2). 이제 단가를 고치면 다음 조회에서 전량 자동 반영된다.
    struct DayAgg: Codable {
        /// `rateKey(model:fast:)` → 토큰. 대화형/자동화 각각.
        var i: [String: Tally] = [:]
        var a: [String: Tally] = [:]

        static func merge(_ lhs: inout [String: Tally], _ rhs: [String: Tally]) {
            for (key, tally) in rhs {
                var acc = lhs[key] ?? Tally(); acc += tally; lhs[key] = acc
            }
        }
    }
    struct FileEntry: Codable {
        var mtime: Double
        /// 이 파일의 메시지를 **전부** 센 집계.
        var days: [String: DayAgg]
        /// 이 파일에 든 메시지 id 해시(8바이트씩 이어 붙임). 파일 간 중복 판정에 쓴다.
        var ids = Foundation.Data()
        /// 다른 파일이 이미 센 메시지를 뺀 집계. 겹치는 메시지가 없으면 nil.
        var net: Net?

        struct Net: Codable {
            var excluded: Int
            var days: [String: DayAgg]
        }
    }
    private struct Cache: Codable {
        var version = cacheVersion
        var files: [String: FileEntry] = [:]
    }
    /// 2: Tally(전 항목 토큰) 스키마 + message.id 중복 제거 + subagents 포함.
    /// 3: 캐시 write를 5m/1h로 분리(Tally 키 변경) + 단가 테이블 세대 정정.
    /// 4: 비용(파생값) 대신 모델·speed별 토큰을 저장 → 단가 변경이 자동 반영된다.
    /// 5: 파일별 메시지 id 해시(`ids`) + 파일 간 중복 제외 집계(`net`) 추가.
    private static let cacheVersion = 5

    private static func loadCache(from url: URL) -> Cache {
        guard let data = try? Foundation.Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Cache.self, from: data),
              c.version == cacheVersion else {
            return Cache()
        }
        return c
    }

    private static func saveCache(_ cache: Cache, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
        // 캐시 키가 프로젝트 절대경로 그대로다(사내 경로 포함). credentials.json과 같은
        // 0600으로 좁힌다 — atomic write가 파일을 갈아치우므로 매 저장 후 다시 지정한다.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
