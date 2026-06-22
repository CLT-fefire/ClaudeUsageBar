import SwiftUI

// 테마 시스템. 시각 토큰 + 폼(form) 디스크리미네이터를 한곳에서 공급한다.
// 기본 .liquidGlass 는 현행 UI 와 픽셀 동등(모든 값 = 기존 리터럴, overlay/glow 없음).
// 미래지향 테마는 형태(면·게이지·진행·오버레이)부터 교체한다.
// 설계 상세: SharedDocs/knowledge/claude-usage-bar/plans/theme-system-20260622.md

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - 전역 상수 (테마축 아님 — 모든 테마 공통 수치)

enum Metrics {
    static let cardLarge: CGFloat = 16
    static let cardMedium: CGFloat = 14
    static let tooltip: CGFloat = 8

    static let heroTrackHeight: CGFloat = 7
    static let rowTrackHeight: CGFloat = 4
    static let minFill: CGFloat = 2

    static let glassSpacing: CGFloat = 14

    static let trackHero = 0.12
    static let trackRow = 0.08
    static let heroTint = 0.10
    static let badgeTint = 0.12
    static let segmentTint = 0.55
    static let fillEnd = 0.7
    static let heroUnit = 0.7
    static let dividerOpacity = 0.4
    static let chartDimmed = 0.4
    static let chartGrid = 0.08
    static let chartRule = 0.12
    static let tooltipStroke = 0.12
    static let tooltipStrokeWidth: CGFloat = 0.5

    // 미래지향 공통
    static let ringDiameter: CGFloat = 116
    static let ringWidth: CGFloat = 9
    static let segmentCells = 16
    static let bracketLen: CGFloat = 10
}

/// severity 임계값은 정책이지 테마축이 아니다. 테마 스왑이 경고 타이밍을 옮기지 못하게 분리.
enum SeverityPolicy {
    static let warn = 60
    static let crit = 85
}

// MARK: - 테마 값 토큰

struct Palette {
    var accent: Color
    var normal: Color
    var warning: Color
    var critical: Color
    /// 트랙·그리드·rule·tooltip stroke 등 hairline 색. LiquidGlass = .white(불투명도는 Metrics).
    var hairline: Color
    var chartInteractive: Color
    var chartAutomation: Color
    var segmentSelectedText: Color
    var errorText: Color
    /// flat 면 채움/테두리(불투명 다크 테마용). glass 테마는 미사용.
    var surfaceFill: Color
    var surfaceStroke: Color
    // nil = 시스템 시맨틱 색 위임. LiquidGlass = 전부 nil. (다크 고정 테마는 forcesDark 로 자동 대응)
    var textPrimary: Color?
    var textSecondary: Color?
    var textTertiary: Color?
    /// 라디얼 링 그라디언트(있으면 단색 대신). Holo 전용.
    var ringGradient: [Color]? = nil
    /// 금속 베벨 그라디언트 [상단밝음, 중앙, 하단어두움]. Titanium 전용.
    var metalBevel: [Color]? = nil
}

// MARK: - 폼 디스크리미네이터

enum SurfaceStyle { case glass, flat, neonSlab, blueprint, metal }
enum GaugeKind { case capsuleBar, radialRing, blockChars, blueprintDimension, embossedBar }
enum BarKind { case capsule, segments, blockChars, dimension, embossedBar }
enum FrameKind { case none, cornerBrackets }      // 후속: asciiFieldset
enum BgKind { case none, scanlines, perspectiveGrid, draftingGrid }

// MARK: - Theme

struct Theme {
    let id: ThemeID
    var palette: Palette
    var surface: SurfaceStyle
    var heroGauge: GaugeKind
    var quotaBar: BarKind
    var frameOverlay: FrameKind
    var bgOverlay: BgKind
    var forcesDark: Bool
    /// 루트에 1회 적용할 폰트 design(없으면 기존 혼합 유지). LiquidGlass = nil.
    var bodyFontDesign: Font.Design?
    /// hero 카드 상단 그라디언트 띠(sun-stripe). Holo 전용.
    var heroStripe: [Color]? = nil

    /// 텍스트 계층 색 — 팔레트값 우선, 없으면 시스템 시맨틱.
    var primaryStyle: AnyShapeStyle { palette.textPrimary.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary) }
    var secondaryStyle: AnyShapeStyle { palette.textSecondary.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary) }
    var tertiaryStyle: AnyShapeStyle { palette.textTertiary.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary) }

    func severityColor(_ severity: ClaudeUsageProbe.Quota.Severity, percent: Int) -> Color {
        switch severity {
        case .critical: return palette.critical
        case .warning: return palette.warning
        case .normal, .unknown: return percentColor(percent)
        }
    }

    func percentColor(_ pct: Int) -> Color {
        switch pct {
        case ..<SeverityPolicy.warn: return palette.normal
        case ..<SeverityPolicy.crit: return palette.warning
        default: return palette.critical
        }
    }
}

// MARK: - ThemeID + factory

enum ThemeID: String, CaseIterable {
    case liquidGlass
    case tacticalHUD
    case phosphor
    case holo
    case cyanotype
    case titaniumDeck

    var label: String {
        switch self {
        case .liquidGlass: return "유리"
        case .tacticalHUD: return "HUD"
        case .phosphor: return "터미널"
        case .holo: return "홀로"
        case .cyanotype: return "청사진"
        case .titaniumDeck: return "메탈릭"
        }
    }

    func make() -> Theme {
        switch self {
        case .liquidGlass:
            return Theme(
                id: .liquidGlass,
                palette: Palette(
                    accent: .accentColor,
                    normal: .green, warning: .orange, critical: .red,
                    hairline: .white,
                    chartInteractive: .accentColor, chartAutomation: .orange,
                    segmentSelectedText: .white, errorText: .red,
                    surfaceFill: .clear, surfaceStroke: .clear,
                    textPrimary: nil, textSecondary: nil, textTertiary: nil
                ),
                surface: .glass,
                heroGauge: .capsuleBar, quotaBar: .capsule,
                frameOverlay: .none, bgOverlay: .none,
                forcesDark: true, bodyFontDesign: nil
            )

        case .tacticalHUD:
            let amber = Color(hex: 0xFFB000)
            return Theme(
                id: .tacticalHUD,
                palette: Palette(
                    accent: amber,
                    normal: amber, warning: amber, critical: Color(hex: 0xFF3B30),
                    hairline: amber,
                    chartInteractive: amber, chartAutomation: Color(hex: 0x8A8576),
                    segmentSelectedText: Color(hex: 0x0C0F0E),
                    errorText: Color(hex: 0xFF3B30),
                    surfaceFill: Color(hex: 0x0C0F0E), surfaceStroke: amber.opacity(0.22),
                    textPrimary: Color(hex: 0xF2EAD8),
                    textSecondary: Color(hex: 0x8A8576),
                    textTertiary: Color(hex: 0x5E6157)
                ),
                surface: .flat,
                heroGauge: .radialRing, quotaBar: .segments,
                frameOverlay: .cornerBrackets, bgOverlay: .scanlines,
                forcesDark: true, bodyFontDesign: .monospaced
            )

        case .phosphor:
            let green = Color(hex: 0x33FF66)
            return Theme(
                id: .phosphor,
                palette: Palette(
                    accent: green,
                    normal: green, warning: Color(hex: 0xFFB000), critical: Color(hex: 0xFF3B30),
                    hairline: green,
                    chartInteractive: green, chartAutomation: Color(hex: 0xFFB000),
                    segmentSelectedText: Color(hex: 0x0B0F0B),
                    errorText: Color(hex: 0xFF3B30),
                    surfaceFill: Color(hex: 0x0B0F0B), surfaceStroke: Color(hex: 0x1E9E4A),
                    textPrimary: green, textSecondary: Color(hex: 0x2BBF55), textTertiary: Color(hex: 0x1E9E4A)
                ),
                surface: .flat,
                heroGauge: .blockChars, quotaBar: .blockChars,
                frameOverlay: .none, bgOverlay: .scanlines,
                forcesDark: true, bodyFontDesign: .monospaced
            )

        case .holo:
            let magenta = Color(hex: 0xFF2BD6)
            let cyan = Color(hex: 0x22E6FF)
            return Theme(
                id: .holo,
                palette: Palette(
                    accent: cyan,
                    normal: magenta, warning: Color(hex: 0xFF8A3D), critical: Color(hex: 0xFF3B6B),
                    hairline: cyan,
                    chartInteractive: cyan, chartAutomation: magenta,
                    segmentSelectedText: Color(hex: 0x16093A),
                    errorText: Color(hex: 0xFF3B6B),
                    surfaceFill: Color(hex: 0x16093A), surfaceStroke: magenta,
                    textPrimary: Color(hex: 0xF4ECFF), textSecondary: nil, textTertiary: nil,
                    ringGradient: [magenta, cyan]
                ),
                surface: .neonSlab,
                heroGauge: .radialRing, quotaBar: .segments,
                frameOverlay: .cornerBrackets, bgOverlay: .perspectiveGrid,
                forcesDark: true, bodyFontDesign: nil,
                heroStripe: [magenta, Color(hex: 0xFF8A3D)]
            )

        case .cyanotype:
            let cyan = Color(hex: 0x7FE0FF)
            return Theme(
                id: .cyanotype,
                palette: Palette(
                    accent: cyan,
                    normal: cyan, warning: Color(hex: 0xF2C14E), critical: Color(hex: 0xFF6B5B),
                    hairline: Color(hex: 0xDCE8F2),
                    chartInteractive: Color(hex: 0xF4F9FF), chartAutomation: Color(hex: 0x7FBFE6),
                    segmentSelectedText: Color(hex: 0x10395E),
                    errorText: Color(hex: 0xFF6B5B),
                    surfaceFill: Color(hex: 0x10395E), surfaceStroke: Color(hex: 0xDCE8F2),
                    textPrimary: Color(hex: 0xF4F9FF), textSecondary: Color(hex: 0xA8C4DC), textTertiary: Color(hex: 0x6E92B2)
                ),
                surface: .blueprint,
                heroGauge: .blueprintDimension, quotaBar: .dimension,
                frameOverlay: .none, bgOverlay: .draftingGrid,
                forcesDark: true, bodyFontDesign: .monospaced
            )

        case .titaniumDeck:
            return Theme(
                id: .titaniumDeck,
                palette: Palette(
                    accent: Color(hex: 0xE8913A),
                    normal: Color(hex: 0x9FB0C0), warning: Color(hex: 0xE8913A), critical: Color(hex: 0xE5462C),
                    hairline: Color(hex: 0x4A535C),
                    chartInteractive: Color(hex: 0xAEB9C4), chartAutomation: Color(hex: 0xB08A5A),
                    segmentSelectedText: Color(hex: 0x23282E),
                    errorText: Color(hex: 0xE5462C),
                    surfaceFill: Color(hex: 0x23282E), surfaceStroke: Color(hex: 0x4A535C),
                    textPrimary: Color(hex: 0xE6EBF0), textSecondary: Color(hex: 0x94A0AC), textTertiary: Color(hex: 0x5C6770),
                    metalBevel: [Color(hex: 0x3A424B), Color(hex: 0x23282E), Color(hex: 0x171B20)]
                ),
                surface: .metal,
                heroGauge: .embossedBar, quotaBar: .embossedBar,
                frameOverlay: .none, bgOverlay: .none,
                forcesDark: true, bodyFontDesign: .default
            )
        }
    }
}

// MARK: - Environment

extension EnvironmentValues {
    @Entry var theme: Theme = ThemeID.liquidGlass.make()
}

extension View {
    /// 루트 폰트 design 조건부 적용(nil이면 무변경 → LiquidGlass 무회귀).
    @ViewBuilder
    func appFontDesign(_ design: Font.Design?) -> some View {
        if let design { fontDesign(design) } else { self }
    }

    /// 루트 기본 텍스트 색 조건부 적용(nil이면 무변경). 명시 색은 그대로 우선.
    @ViewBuilder
    func appForeground(_ color: Color?) -> some View {
        if let color { foregroundStyle(color) } else { self }
    }
}

/// 블록문자 게이지 문자열: [████░░].
func blockBar(_ percent: Int, cells: Int) -> String {
    let filled = max(0, min(cells, Int((Double(percent) / 100 * Double(cells)).rounded())))
    return "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: cells - filled) + "]"
}

/// 가용 폭을 꽉 채우는 블록문자 게이지 — 폭에 맞춰 셀 수를 동적 산정(끝에서 끝까지).
struct BlockBar: View {
    let percent: Int
    let color: Color
    var fontSize: CGFloat = 11
    var body: some View {
        GeometryReader { geo in
            let cells = max(4, Int(geo.size.width / (fontSize * 0.6)) - 2)  // SF Mono advance ≈ 0.6em, 양끝 대괄호 2칸
            Text(blockBar(percent, cells: cells))
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: fontSize + 3)
    }
}

// MARK: - 표면(surface) 모디파이어

extension View {
    @ViewBuilder
    func themedCard(_ t: Theme, radius: CGFloat) -> some View {
        switch t.surface {
        case .glass:
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        case .flat, .neonSlab:
            self.flatSurface(t)
        case .blueprint:
            self.blueprintSurface(t, radius: 2)
        case .metal:
            self.metalSurface(t, radius: radius)
        }
    }

    @ViewBuilder
    func themedHero(_ t: Theme, tint: Color?) -> some View {
        switch t.surface {
        case .glass:
            glassEffect(
                tint.map { Glass.regular.tint($0.opacity(Metrics.heroTint)) } ?? Glass.regular,
                in: RoundedRectangle(cornerRadius: Metrics.cardLarge)
            )
        case .flat, .neonSlab:
            self.flatSurface(t)
        case .blueprint:
            self.blueprintSurface(t, radius: 2)
        case .metal:
            self.metalSurface(t, radius: Metrics.cardLarge)
        }
    }

    @ViewBuilder
    func themedBadge(_ t: Theme) -> some View {
        switch t.surface {
        case .glass:
            glassEffect(.regular.tint(t.palette.accent.opacity(Metrics.badgeTint)), in: Capsule())
        case .flat, .neonSlab:
            background(t.palette.accent.opacity(Metrics.badgeTint), in: Capsule())
                .overlay(Capsule().stroke(t.palette.surfaceStroke, lineWidth: 0.5))
        case .blueprint:
            background(Color.clear, in: Capsule())
                .overlay(Capsule().stroke(t.palette.accent.opacity(0.8), lineWidth: 0.75))
        case .metal:
            background(
                LinearGradient(colors: t.palette.metalBevel ?? [t.palette.surfaceFill, t.palette.surfaceFill],
                               startPoint: .top, endPoint: .bottom),
                in: Capsule()
            )
            .overlay(Capsule().stroke(t.palette.surfaceStroke.opacity(0.6), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func themedSegment(_ t: Theme, selected: Bool) -> some View {
        switch t.surface {
        case .glass:
            glassEffect(
                selected
                    ? .regular.tint(t.palette.accent.opacity(Metrics.segmentTint)).interactive()
                    : .regular.interactive(),
                in: Capsule()
            )
        case .flat, .neonSlab, .blueprint, .metal:
            background(
                selected ? t.palette.accent.opacity(0.85) : Color.clear,
                in: RoundedRectangle(cornerRadius: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(t.palette.accent.opacity(selected ? 0 : 0.3), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    func themedTooltip(_ t: Theme) -> some View {
        switch t.surface {
        case .glass:
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Metrics.tooltip))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.tooltip)
                        .stroke(t.palette.hairline.opacity(Metrics.tooltipStroke), lineWidth: Metrics.tooltipStrokeWidth)
                )
        case .flat, .neonSlab, .blueprint, .metal:
            background(t.palette.surfaceFill.opacity(0.96), in: RoundedRectangle(cornerRadius: Metrics.tooltip))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.tooltip)
                        .stroke(t.palette.surfaceStroke, lineWidth: 0.5)
                )
        }
    }

    /// 액션 버튼 스타일. 유리 테마 = 커스텀 liquid glass(라벨 색 명시로 가독성 보장), 그 외 = 시스템 표준.
    @ViewBuilder
    func themedButton(_ t: Theme, prominent: Bool = false) -> some View {
        switch t.surface {
        case .glass:
            buttonStyle(GlassActionButtonStyle(prominent: prominent, tint: t.palette.accent))
        case .metal:
            buttonStyle(MetalActionButtonStyle(prominent: prominent, accent: t.palette.accent))
        case .flat, .neonSlab, .blueprint:
            if prominent {
                buttonStyle(.borderedProminent).tint(t.palette.accent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }

    /// 불투명 다크 면 + hairline 테두리 (+ 코너 브래킷). neonSlab 이면 발광 테두리.
    fileprivate func flatSurface(_ t: Theme) -> some View {
        let neon = (t.surface == .neonSlab)
        let radius: CGFloat = neon ? 2 : 0
        return background(t.palette.surfaceFill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(t.palette.surfaceStroke, lineWidth: neon ? 1 : 0.5)
                    .shadow(color: neon ? t.palette.accent.opacity(0.6) : Color.clear, radius: neon ? 4 : 0)
            )
            .overlay {
                if t.frameOverlay == .cornerBrackets {
                    CornerBrackets().stroke(t.palette.accent.opacity(0.6), lineWidth: 1.5)
                }
            }
    }

    /// 청사진 면 — 채움 없는 stroke-only 도면 프레임.
    fileprivate func blueprintSurface(_ t: Theme, radius: CGFloat) -> some View {
        background(t.palette.surfaceFill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(t.palette.hairline.opacity(0.55), lineWidth: 0.75))
    }

    /// 금속 면 — 수직 명암 베벨 + 상단 specular/하단 contact + 외곽 rim + 드롭섀도.
    fileprivate func metalSurface(_ t: Theme, radius: CGFloat) -> some View {
        let bevel = t.palette.metalBevel ?? [t.palette.surfaceFill, t.palette.surfaceFill]
        return background(
            LinearGradient(colors: bevel, startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: radius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(
                    LinearGradient(
                        colors: [Color(hex: 0xEAF0F6).opacity(0.45), Color.clear, Color(hex: 0x070A0D).opacity(0.5)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(t.palette.surfaceStroke.opacity(0.6), lineWidth: 0.5))
        .shadow(color: Color(hex: 0x070A0D).opacity(0.45), radius: 4, y: 2)
    }
}

/// 유리 테마 액션 버튼 — 실제 .glassEffect 캡슐 + 명시적 라벨 색으로 가독성 보장.
/// (시스템 .glass 는 라벨을 tint색으로 그려 컬러 글라스 위 대비가 약함)
struct GlassActionButtonStyle: ButtonStyle {
    var prominent: Bool
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .glassEffect(
                prominent ? .regular.tint(tint).interactive() : .regular.interactive(),
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

// MARK: - 진행 게이지 빌더 (면과 직교 축)

@ViewBuilder
func themedHeroGauge(_ t: Theme, percent: Int, color: Color) -> some View {
    switch t.heroGauge {
    case .capsuleBar:
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(t.palette.hairline.opacity(Metrics.trackHero))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color, color.opacity(Metrics.fillEnd)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(Metrics.minFill, geo.size.width * CGFloat(percent) / 100))
            }
        }
        .frame(height: Metrics.heroTrackHeight)
    case .radialRing, .blockChars, .blueprintDimension, .embossedBar:
        // hero 는 MenuContentView 에서 테마별로 직접 구성.
        EmptyView()
    }
}

@ViewBuilder
func themedQuotaBar(_ t: Theme, percent: Int, color: Color) -> some View {
    switch t.quotaBar {
    case .capsule:
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(t.palette.hairline.opacity(Metrics.trackRow))
                Capsule()
                    .fill(color)
                    .frame(width: max(Metrics.minFill, geo.size.width * CGFloat(percent) / 100))
            }
        }
        .frame(height: Metrics.rowTrackHeight)
    case .segments:
        let cells = Metrics.segmentCells
        let filled = Int((Double(percent) / 100 * Double(cells)).rounded())
        HStack(spacing: 1) {
            ForEach(0..<cells, id: \.self) { i in
                Rectangle()
                    .fill(i < filled ? color : t.palette.hairline.opacity(0.12))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Metrics.heroTrackHeight)
    case .blockChars:
        BlockBar(percent: percent, color: color)
    case .dimension:
        DimensionLine(percent: percent, color: color, track: t.palette.hairline)
    case .embossedBar:
        EmbossedGauge(percent: percent, color: color, height: 6)
    }
}

// MARK: - 미래지향 폼 컴포넌트

/// 라디얼 게이지 링 + 중앙 숫자 (Tactical/Holo hero).
struct RadialGauge: View {
    let percent: Int
    let color: Color
    let track: Color
    var gradient: [Color]? = nil

    private var ringStyle: AnyShapeStyle {
        if let gradient {
            return AnyShapeStyle(AngularGradient(colors: gradient + [gradient.first ?? color], center: .center))
        }
        return AnyShapeStyle(color)
    }

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: Metrics.ringWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(percent, 0), 100)) / 100)
                .stroke(ringStyle, style: StrokeStyle(lineWidth: Metrics.ringWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: 3)
            // 12·3·6·9시 메이저 틱
            ForEach(0..<4, id: \.self) { i in
                Rectangle()
                    .fill(track)
                    .frame(width: 1.5, height: 5)
                    .offset(y: -(Metrics.ringDiameter / 2 - 1))
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            VStack(spacing: 1) {
                Text("\(percent)")
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                Text("SESSION %")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Metrics.ringDiameter, height: Metrics.ringDiameter)
    }
}

/// 네 모서리 L자 프레이밍 마크.
struct CornerBrackets: Shape {
    var len: CGFloat = Metrics.bracketLen
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + len)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + len, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - len, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + len))
        p.move(to: CGPoint(x: r.minX, y: r.maxY - len)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + len, y: r.maxY))
        p.move(to: CGPoint(x: r.maxX - len, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - len))
        return p
    }
}

/// CRT 스캔라인 오버레이 (저대비, 입력 통과).
struct Scanlines: View {
    var color: Color = Color(hex: 0x33FF66)
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                         with: .color(color.opacity(0.05)))
                y += 3
            }
        }
        .allowsHitTesting(false)
    }
}

/// 터미널 블링킹 블록 커서 (reduceMotion 시 정지).
struct BlinkingCursor: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = true
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 10, height: 24)
            .opacity(on ? 1 : 0.15)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    on = false
                }
            }
    }
}

/// 유리 테마용 은은한 컬러 필드 — Liquid Glass 가 굴절·반사할 콘텐츠를 제공한다.
/// (Apple 문서: Liquid Glass는 "뒤 콘텐츠를 블러하고 주변 색·빛을 반사" → 뒤에 색이 있어야 유리감이 산다.)
struct GlassBackdrop: View {
    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                .init(0, 0), .init(0.5, 0), .init(1, 0),
                .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                .init(0, 1), .init(0.5, 1), .init(1, 1)
            ],
            colors: [
                .blue.opacity(0.18), .purple.opacity(0.14), .cyan.opacity(0.16),
                .indigo.opacity(0.12), .teal.opacity(0.12), .purple.opacity(0.14),
                .cyan.opacity(0.16), .blue.opacity(0.14), .indigo.opacity(0.18)
            ]
        )
        .allowsHitTesting(false)
    }
}

/// 아웃런 perspective 그리드 호라이즌 (배경, 저대비).
struct PerspectiveGrid: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let horizon = size.height * 0.55
            let vanish = CGPoint(x: size.width / 2, y: horizon)
            let cols = 9
            for i in 0...cols {
                let x = size.width * CGFloat(i) / CGFloat(cols)
                var p = Path(); p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: vanish)
                ctx.stroke(p, with: .color(color.opacity(0.16)), lineWidth: 0.5)
            }
            var y = horizon
            var step: CGFloat = 4
            while y < size.height {
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(color.opacity(0.13)), lineWidth: 0.5)
                y += step; step *= 1.5
            }
        }
        .allowsHitTesting(false)
    }
}

/// 청사진 모눈 도면지 배경 (저대비).
struct DraftingGrid: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 8
            var x: CGFloat = 0
            while x < size.width {
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(color.opacity(0.06)), lineWidth: 0.5)
                x += gap
            }
            var y: CGFloat = 0
            while y < size.height {
                ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                           with: .color(color.opacity(0.06)), lineWidth: 0.5)
                y += gap
            }
        }
        .allowsHitTesting(false)
    }
}

/// 청사진 치수선 게이지 — baseline + 양끝 tick + 진행분 실선 + arrowhead. (값은 옆 라벨이 표기)
struct DimensionLine: View {
    let percent: Int
    let color: Color
    let track: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = CGFloat(min(max(percent, 0), 100)) / 100
            ZStack(alignment: .leading) {
                Rectangle().fill(track.opacity(0.4)).frame(width: w, height: 1).offset(y: 7)
                Rectangle().fill(track.opacity(0.6)).frame(width: 1, height: 11).offset(x: 0, y: 2)
                Rectangle().fill(track.opacity(0.6)).frame(width: 1, height: 11).offset(x: w - 1, y: 2)
                Rectangle().fill(color).frame(width: max(2, w * p), height: 1.5).offset(y: 6.75)
                Text("▸").font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                    .offset(x: max(-2, w * p - 5), y: 1.5)
            }
        }
        .frame(height: 16)
    }
}

/// 메탈릭 음각 트랙 + 볼록 금속 fill 게이지.
struct EmbossedGauge: View {
    let percent: Int
    let color: Color
    var height: CGFloat = 12
    var body: some View {
        GeometryReader { geo in
            let p = CGFloat(min(max(percent, 0), 100)) / 100
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color(hex: 0x12161A))
                    .overlay(
                        RoundedRectangle(cornerRadius: height / 2)
                            .stroke(
                                LinearGradient(colors: [Color.black.opacity(0.55), Color.clear],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 1
                            )
                    )
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(color)
                    .overlay(
                        RoundedRectangle(cornerRadius: height / 2)
                            .fill(
                                LinearGradient(colors: [Color.white.opacity(0.4), Color.clear, Color.black.opacity(0.25)],
                                               startPoint: .top, endPoint: .bottom)
                            )
                    )
                    .frame(width: max(Metrics.minFill, geo.size.width * p))
            }
        }
        .frame(height: height)
    }
}

/// 메탈릭 액션 버튼 — 베벨 캡슐, press 시 그라디언트 반전(눌린 음각).
struct MetalActionButtonStyle: ButtonStyle {
    var prominent: Bool
    var accent: Color
    func makeBody(configuration: Configuration) -> some View {
        let base: [Color] = prominent
            ? [accent.opacity(0.95), accent.opacity(0.6)]
            : [Color(hex: 0x454D56), Color(hex: 0x23282E)]
        let grad = configuration.isPressed ? Array(base.reversed()) : base
        return configuration.label
            .foregroundStyle(prominent ? Color.white : Color(hex: 0xE6EBF0))
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(LinearGradient(colors: grad, startPoint: .top, endPoint: .bottom), in: Capsule())
            .overlay(
                Capsule().stroke(
                    LinearGradient(colors: [Color(hex: 0xEAF0F6).opacity(0.4), Color.clear, Color.black.opacity(0.5)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75
                )
            )
            .shadow(color: Color.black.opacity(0.4), radius: 2, y: 1)
    }
}

extension View {
    /// 금속 각인 텍스트(아래 highlight·위 shadow 2겹). hero 숫자·큰 라벨에만.
    func embossText() -> some View {
        shadow(color: .black.opacity(0.6), radius: 0, y: 1)
            .shadow(color: .white.opacity(0.18), radius: 0, y: -0.5)
    }
}
