#!/usr/bin/env swift
// AppIcon.icns 생성기.
// 사용: swift scripts/make_icon.swift
// 출력: Resources/AppIcon.icns
//
// 디자인: 인디고→블루 그라데이션 squircle 배경 + 흰색 "%" 글리프.

import AppKit
import CoreText

// MARK: - 디자인 토큰
let canvasCornerRatio: CGFloat = 0.22       // macOS Big Sur+ squircle 비율
let glyphSizeRatio:    CGFloat = 0.62       // 캔버스 대비 글리프 크기
let bgTopColor    = NSColor(srgbRed: 0.42, green: 0.32, blue: 0.88, alpha: 1)
let bgBottomColor = NSColor(srgbRed: 0.20, green: 0.13, blue: 0.55, alpha: 1)
let glyphColor    = NSColor.white
let glyph         = "%"

// MARK: - Rendering

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    // 1. Squircle clip
    let cornerRadius = size * canvasCornerRatio
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let clipPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(clipPath)
    ctx.clip()

    // 2. Gradient background
    let colors = [bgTopColor.cgColor, bgBottomColor.cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end:   CGPoint(x: size, y: 0),
        options: []
    )

    // 3. Subtle highlight (top-left glow for glass-like feel)
    let highlightColors = [
        NSColor.white.withAlphaComponent(0.18).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor
    ] as CFArray
    let highlight = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: highlightColors, locations: [0, 1])!
    ctx.drawRadialGradient(
        highlight,
        startCenter: CGPoint(x: size * 0.3, y: size * 0.85), startRadius: 0,
        endCenter:   CGPoint(x: size * 0.3, y: size * 0.85), endRadius: size * 0.6,
        options: []
    )

    // 4. Glyph (% in SF Rounded Heavy)
    let fontSize = size * glyphSizeRatio
    let font: NSFont = {
        if let desc = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
            .fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: desc, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        }
        return NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    }()

    // 텍스트는 NSAttributedString에서 NSString.draw로 그리되,
    // 광학 중심 보정을 위해 typographic bounds로 정확히 센터링.
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: glyphColor,
        .kern: 0
    ]
    let attrStr = NSAttributedString(string: glyph, attributes: attrs)
    let line = CTLineCreateWithAttributedString(attrStr)
    let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])

    // 텍스트 베이스라인 좌표로 변환
    let textX = (size - bounds.width) / 2 - bounds.minX
    let textY = (size - bounds.height) / 2 - bounds.minY
    ctx.textPosition = CGPoint(x: textX, y: textY)

    // % 글리프는 광학 중심이 약간 위쪽에 쏠려있어서 1.5% 아래로 미세 조정
    ctx.textPosition.y -= size * 0.015

    // Shadow for depth
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01),
                  blur: size * 0.02,
                  color: NSColor.black.withAlphaComponent(0.25).cgColor)

    CTLineDraw(line, ctx)

    return image
}

// MARK: - PNG export

func savePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make_icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG 변환 실패"])
    }
    try png.write(to: url)
}

// MARK: - 표준 .iconset 사이즈 표

let entries: [(filename: String, pixelSize: CGFloat)] = [
    ("icon_16x16.png",        16),
    ("icon_16x16@2x.png",     32),
    ("icon_32x32.png",        32),
    ("icon_32x32@2x.png",     64),
    ("icon_128x128.png",      128),
    ("icon_128x128@2x.png",   256),
    ("icon_256x256.png",      256),
    ("icon_256x256@2x.png",   512),
    ("icon_512x512.png",      512),
    ("icon_512x512@2x.png",   1024),
]

// MARK: - 메인

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetDir = projectRoot.appendingPathComponent("AppIcon.iconset")
let resourcesDir = projectRoot.appendingPathComponent("Resources")
let icnsOut = resourcesDir.appendingPathComponent("AppIcon.icns")

let fm = FileManager.default
try? fm.removeItem(at: iconsetDir)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

print("▶ Rendering icon sizes…")
for entry in entries {
    let img = renderIcon(size: entry.pixelSize)
    let outURL = iconsetDir.appendingPathComponent(entry.filename)
    try savePNG(img, to: outURL)
    print("  \(entry.filename) (\(Int(entry.pixelSize))px)")
}

print("▶ Packaging .icns via iconutil…")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsOut.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    print("❌ iconutil 실패 (exit \(iconutil.terminationStatus))")
    exit(1)
}

// 임시 .iconset 폴더 정리
try? fm.removeItem(at: iconsetDir)

print("✅ Generated: \(icnsOut.path)")
