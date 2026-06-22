#!/bin/bash
# ClaudeUsageBar를 .app 번들로 패키징.
# 사용: ./make_app.sh
# 결과물: ./ClaudeUsageBar.app

set -euo pipefail

cd "$(dirname "$0")"

echo "▶ Building release binary…"
swift build -c release

APP="ClaudeUsageBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/ClaudeUsageBar "$APP/Contents/MacOS/ClaudeUsageBar"

# 아이콘이 없으면 자동 생성 (Resources/AppIcon.icns)
if [ ! -f "Resources/AppIcon.icns" ]; then
    echo "▶ AppIcon.icns 없음 → scripts/make_icon.swift로 자동 생성"
    swift scripts/make_icon.swift
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClaudeUsageBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.claudeusagebar</string>
    <key>CFBundleName</key>
    <string>ClaudeUsageBar</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Usage Bar</string>
    <key>CFBundleShortVersionString</key>
    <string>0.10.0</string>
    <key>CFBundleVersion</key>
    <string>10</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# 코드 서명 — 우선순위:
#   1) Developer ID Application — 배포용 cert. 다운로드 배포 시 Gatekeeper "손상됨/미확인
#      개발자" 하드블록을 제거하고(공증 전이라 최초 1회 우클릭→열기만 필요), hardened
#      runtime + secure timestamp를 적용한다. v0.6.0부터 서명 dmg를 GitHub Release로 배포.
#   2) Apple Development        — 개발용 cert. 로컬 실행엔 충분하나 배포엔 부적합(~1년 만료).
#   3) ad-hoc                   — cert 없음. 로컬 빌드 실행용(다운로드 배포엔 부적합).
# 어느 식별자도 코드/repo에 하드코딩하지 않고 로컬 키체인에서 자동 탐지만 한다.
# (이 앱은 v0.5.0부터 Keychain을 쓰지 않고 자체 PKCE OAuth + 파일 저장이라 서명은 배포·무결성용.)
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application:" \
    | head -1 \
    | awk -F'"' '{print $2}')
SIGN_KIND="Developer ID"

if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Apple Development:" \
        | head -1 \
        | awk -F'"' '{print $2}')
    SIGN_KIND="Apple Development"
fi

if [ -n "$IDENTITY" ]; then
    echo "▶ Signing with ($SIGN_KIND): $IDENTITY"
    if [ "$SIGN_KIND" = "Developer ID" ]; then
        # secure timestamp는 네트워크 필요(공증 사전요건). Developer ID 경로에만 적용.
        codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP"
    else
        codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
    fi
else
    echo "▶ 서명 인증서 없음 → ad-hoc 서명 (Keychain 매번 다시 물음)"
    codesign --force --deep --sign - "$APP"
fi

echo "✅ Built: $(pwd)/$APP"
echo ""
echo "실행: open $(pwd)/$APP"
echo "/Applications/로 옮기려면: mv $APP /Applications/"
