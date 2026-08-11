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
/// - 비용은 모델 단가 하드코딩 기반 **추정**이며 캐시 토큰까지 포함한다.
enum LocalUsageReader {

    enum Source { case interactive, automation }

    /// 토큰 내역. `total`이 차트에 쓰는 실사용량.
    struct Tally: Sendable, Equatable, Codable {
        var input = 0
        var output = 0
        var cacheWrite = 0
        var cacheRead = 0

        var total: Int { input + output + cacheWrite + cacheRead }

        static func += (lhs: inout Tally, rhs: Tally) {
            lhs.input += rhs.input; lhs.output += rhs.output
            lhs.cacheWrite += rhs.cacheWrite; lhs.cacheRead += rhs.cacheRead
        }
    }

    /// 하루치 집계 (출처별 토큰 내역 + 추정 비용 USD).
    struct DayBucket: Sendable, Equatable, Identifiable {
        let day: Date          // 로컬 자정 기준 날짜
        let interactive: Tally
        let automation: Tally
        let interactiveCost: Double
        let automationCost: Double

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

    /// 백그라운드에서 호출할 것. 파일 IO + JSON 파싱이 무겁다.
    static func scan(windowDays: Int = defaultWindowDays) -> Data {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else {
            return .empty
        }

        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86_400)
        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"
        dayFmt.calendar = Calendar.current
        dayFmt.timeZone = .current
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        var cache = loadCache()
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

        cache.files = current  // 윈도우 밖/삭제 파일은 자연 정리
        saveCache(cache)

        // 파일별 일 집계를 날짜 기준으로 합산
        var merged: [String: DayAgg] = [:]
        for entry in current.values {
            for (day, a) in entry.days {
                var m = merged[day] ?? DayAgg()
                m.i += a.i; m.a += a.a; m.iCost += a.iCost; m.aCost += a.aCost
                merged[day] = m
            }
        }

        var buckets: [DayBucket] = []
        buckets.reserveCapacity(merged.count)
        for (day, m) in merged {
            guard let d = dayFmt.date(from: day) else { continue }
            buckets.append(DayBucket(
                day: d,
                interactive: m.i, automation: m.a,
                interactiveCost: m.iCost, automationCost: m.aCost
            ))
        }
        buckets.sort { $0.day < $1.day }
        return Data(days: buckets, capturedAt: Date())
    }

    // MARK: - 파일 파싱

    private static func parseFile(
        _ url: URL, mtime: Double,
        dayFmt: DateFormatter, isoFrac: ISO8601DateFormatter, isoPlain: ISO8601DateFormatter
    ) -> FileEntry? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        // 서브에이전트 로그는 entrypoint가 부모 세션 값이라 경로로 판정한다.
        let isSubagent = url.path.contains("/subagents/")

        var days: [String: DayAgg] = [:]
        var source: Source? = isSubagent ? .automation : nil
        var seenMessages = Set<String>()   // content block 분할 라인 중복 제거

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
            if let mid = msg["id"] as? String, !seenMessages.insert(mid).inserted { continue }

            var t = Tally()
            t.input      = intValue(usage["input_tokens"])
            t.output     = intValue(usage["output_tokens"])
            t.cacheWrite = intValue(usage["cache_creation_input_tokens"])
            t.cacheRead  = intValue(usage["cache_read_input_tokens"])
            let model = (msg["model"] as? String) ?? ""
            guard let tsStr = obj["timestamp"] as? String,
                  let ts = isoFrac.date(from: tsStr) ?? isoPlain.date(from: tsStr) else { continue }

            let key = dayFmt.string(from: ts)
            let p = price(for: model)
            let cost = Double(t.input) * p.input + Double(t.output) * p.output
                     + Double(t.cacheWrite) * p.cacheWrite + Double(t.cacheRead) * p.cacheRead

            var a = days[key] ?? DayAgg()
            if (source ?? .interactive) == .automation {
                a.a += t; a.aCost += cost
            } else {
                a.i += t; a.iCost += cost
            }
            days[key] = a
        }
        return FileEntry(mtime: mtime, days: days)
    }

    private static func intValue(_ v: Any?) -> Int {
        (v as? Int) ?? (v as? Double).map(Int.init) ?? 0
    }

    // MARK: - 모델 단가 (USD per token, 추정)

    private struct Price { let input, output, cacheWrite, cacheRead: Double }

    /// 백만 토큰당 단가를 토큰당으로 환산. 미상 모델은 Sonnet 기준.
    private static func price(for model: String) -> Price {
        let m = model.lowercased()
        let perM: (Double, Double, Double, Double)
        if m.contains("opus") {
            perM = (15, 75, 18.75, 1.5)
        } else if m.contains("haiku") {
            perM = (1, 5, 1.25, 0.10)
        } else { // sonnet + 기본값
            perM = (3, 15, 3.75, 0.30)
        }
        return Price(input: perM.0 / 1e6, output: perM.1 / 1e6,
                     cacheWrite: perM.2 / 1e6, cacheRead: perM.3 / 1e6)
    }

    // MARK: - 캐시 (파일 mtime 기준 증분 파싱)

    private struct DayAgg: Codable {
        var i = Tally(), a = Tally()
        var iCost = 0.0, aCost = 0.0
    }
    private struct FileEntry: Codable {
        var mtime: Double
        var days: [String: DayAgg]
    }
    private struct Cache: Codable {
        var version = cacheVersion
        var files: [String: FileEntry] = [:]
    }
    /// 2: Tally(전 항목 토큰) 스키마 + message.id 중복 제거 + subagents 포함.
    private static let cacheVersion = 2

    private static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ClaudeUsageBar", isDirectory: true)
            .appendingPathComponent("usage-cache.json")
    }

    private static func loadCache() -> Cache {
        guard let data = try? Foundation.Data(contentsOf: cacheURL),
              let c = try? JSONDecoder().decode(Cache.self, from: data),
              c.version == cacheVersion else {
            return Cache()
        }
        return c
    }

    private static func saveCache(_ cache: Cache) {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
