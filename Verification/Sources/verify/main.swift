import SwiftUI
import AppKit

// 실제 StatusCard.swift / Theme.swift 를 심볼릭 링크로 그대로 컴파일해서
// 오프스크린 렌더링한다. 카드 레이아웃 검증 전용 harness.

let comps: [(String, StatusProbe.ComponentStatus)] = [
    ("claude.ai", .operational),
    ("Claude Console (platform.claude.com)", .operational),
    ("Claude API (api.anthropic.com)", .operational),
    ("Claude Code", .operational),
    ("Claude Cowork", .operational),
    ("Claude for Government", .operational),
]

func makeComponents(degraded: Set<String> = [], status: StatusProbe.ComponentStatus = .partialOutage) -> [StatusProbe.Component] {
    comps.enumerated().map { i, c in
        StatusProbe.Component(id: "c\(i)", name: c.0, status: degraded.contains(c.0) ? status : c.1)
    }
}

let healthy = StatusProbe.Snapshot(
    indicator: .allClear, rawDescription: "All Systems Operational",
    components: makeComponents(), incidents: [], maintenances: [], capturedAt: Date()
)

let degraded = StatusProbe.Snapshot(
    indicator: .major, rawDescription: "Partial System Outage",
    components: makeComponents(degraded: ["Claude Code", "Claude API (api.anthropic.com)"]),
    incidents: [
        StatusProbe.Incident(
            id: "i1",
            name: "Elevated errors for Claude Mythos 5, Claude Fable 5, and Claude Sonnet 5",
            impact: .major,
            url: URL(string: "https://stspg.io/bjkywv98sm8d"),
            isInProgress: true
        )
    ],
    maintenances: [], capturedAt: Date()
)

struct Harness: View {
    let snapshot: StatusProbe.Snapshot
    let theme: Theme
    let failed: Bool
    @State var expanded: Bool

    init(snapshot: StatusProbe.Snapshot, theme: Theme, failed: Bool = false, expanded: Bool) {
        self.snapshot = snapshot
        self.theme = theme
        self.failed = failed
        self._expanded = State(initialValue: expanded)
    }

    var body: some View {
        StatusCardWrapper(snapshot: snapshot, failed: failed, expanded: expanded)
            .environment(\.theme, theme)
            .appFontDesign(theme.bodyFontDesign)
            .appForeground(theme.palette.textPrimary)
            // 앱과 동일한 폭(360) - 좌우 패딩(12*2)
            .frame(width: 336)
            .padding(12)
            .background(theme.surface == .metal ? Color(hex: 0x15181C) : theme.palette.surfaceFill)
            .environment(\.colorScheme, .dark)
    }
}

/// @Binding 을 상수로 물려주기 위한 얇은 래퍼.
struct StatusCardWrapper: View {
    let snapshot: StatusProbe.Snapshot
    let failed: Bool
    @State var expanded: Bool

    init(snapshot: StatusProbe.Snapshot, failed: Bool, expanded: Bool) {
        self.snapshot = snapshot
        self.failed = failed
        self._expanded = State(initialValue: expanded)
    }

    var body: some View {
        StatusCard(snapshot: snapshot, failed: failed, expanded: $expanded)
    }
}

@MainActor
func render(_ name: String, _ view: some View) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("✗ \(name) 렌더 실패")
        return
    }
    let url = URL(fileURLWithPath: "shots/\(name).png")
    try? FileManager.default.createDirectory(atPath: "shots", withIntermediateDirectories: true)
    try? png.write(to: url)
    print("✓ \(name).png  \(Int(image.size.width))x\(Int(image.size.height))pt")
}

let cases: [(String, StatusProbe.Snapshot, ThemeID, Bool, Bool)] = [
    ("01-healthy-collapsed-phosphor", healthy, .phosphor, false, false),
    ("02-healthy-expanded-phosphor",  healthy, .phosphor, true,  false),
    ("03-degraded-phosphor",          degraded, .phosphor, false, false),
    ("04-degraded-expanded-phosphor", degraded, .phosphor, true,  false),
    ("05-healthy-failed-phosphor",    healthy, .phosphor, false, true),
    ("06-degraded-cyanotype",         degraded, .cyanotype, false, false),
    ("07-degraded-titaniumDeck",      degraded, .titaniumDeck, false, false),
    ("08-degraded-tacticalHUD",       degraded, .tacticalHUD, false, false),
    ("09-healthy-collapsed-glass",    healthy, .liquidGlass, false, false),
]

/// 점검 중 — 카드는 뜨되 메뉴바 경보는 아니어야 하는 상태 (v0.12.0 리뷰 수정분).
let maintenance = try! StatusProbe.parse(Data("""
{"status":{"indicator":"maintenance","description":"Scheduled Maintenance In Progress"},
 "components":[{"id":"a","name":"claude.ai","status":"operational","group":false},
               {"id":"b","name":"Claude Console (platform.claude.com)","status":"operational","group":false},
               {"id":"c","name":"Claude API (api.anthropic.com)","status":"operational","group":false},
               {"id":"d","name":"Claude Code","status":"under_maintenance","group":false},
               {"id":"e","name":"Claude Cowork","status":"operational","group":false},
               {"id":"f","name":"Claude for Government","status":"operational","group":false}],
 "incidents":[],
 "scheduled_maintenances":[{"id":"m","name":"Claude Code 배포 작업 진행 중","status":"in_progress",
                            "impact":"maintenance","shortlink":"https://stspg.io/m"}]}
""".utf8))

MainActor.assumeIsolated {
    for (name, snap, themeID, expanded, failed) in cases {
        render(name, Harness(snapshot: snap, theme: themeID.make(), failed: failed, expanded: expanded))
    }
    render("10-maintenance-phosphor",
           Harness(snapshot: maintenance, theme: ThemeID.phosphor.make(), expanded: false))

    // 스냅샷을 한 번도 못 받은 경우의 자리표시 카드
    let t = ThemeID.phosphor.make()
    render("11-unavailable-phosphor", StatusUnavailableCard()
        .environment(\.theme, t)
        .appFontDesign(t.bodyFontDesign)
        .appForeground(t.palette.textPrimary)
        .frame(width: 336)
        .padding(12)
        .background(t.palette.surfaceFill)
        .environment(\.colorScheme, .dark))
}

// MenuBarExtra label 레이아웃 실측 — Image+Text를 stack 없이 두면 암묵 세로 스택이
// 되어 상태바 높이(~22pt)에서 잘린다(3차 리뷰 지적). HStack이 가로로 붙는지 확인.
@MainActor
func measure(_ label: String, _ view: some View) -> CGSize {
    let size = ImageRenderer(content: view).nsImage?.size ?? .zero
    print("  \(label): \(Int(size.width))x\(Int(size.height))pt")
    return size
}

MainActor.assumeIsolated {
    print("\n=== 메뉴바 라벨 레이아웃 ===")
    // 기준선: stack 없이 Image+Text를 두면 어떻게 되는지 (암묵 세로 스택)
    let bare = measure("[기준선] stack 없음", UnstackedBaseline())
    // 실측 대상은 **실제 앱 뷰**(MenuBarLabel.swift 심볼릭 링크).
    // 앱에서 HStack이 사라지면 아래 단언이 깨진다.
    let real = measure("[실제] MenuBarLabel(경보 O)", MenuBarLabel(text: "78%", hasOutage: true))
    let normal = measure("[실제] MenuBarLabel(경보 X)", MenuBarLabel(text: "78%", hasOutage: false))

    // 상태바 아이템 높이는 ~22pt. 세로 스택(31pt)이면 잘린다.
    let statusBarHeight: CGFloat = 22
    let checks: [(Bool, String)] = [
        (real.height <= statusBarHeight, "경보 표시 시 높이가 상태바(22pt) 이내 — 현재 \(Int(real.height))pt"),
        (real.height < bare.height, "실제 라벨이 세로 스택 기준선(\(Int(bare.height))pt)보다 낮음"),
        (real.width > normal.width, "경보 글리프가 폭을 늘림 (가로 배치 확인)"),
        (abs(real.height - normal.height) < 1, "경보 유무가 높이를 바꾸지 않음"),
    ]
    for (ok, label) in checks {
        print(ok ? "  ✓ \(label)" : "  ✗ \(label)")
        if !ok { LogicTests.failures += 1 }
    }
}

/// 회귀 기준선 전용 — "stack 없이 두면 이렇게 된다"를 보여주는 대조군.
/// 앱 코드가 아니므로 이것만 통과해도 의미가 없다(실측 대상은 MenuBarLabel).
struct UnstackedBaseline: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
        Text("78%")
    }
}

LogicTests.run()
if LogicTests.failures > 0 { exit(1) }
