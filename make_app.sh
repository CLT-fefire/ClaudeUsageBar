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
    <string>0.3.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
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

# 안정 서명(Stable signing):
# Apple Development 인증서가 있으면 그걸로 서명. 그래야 rebuild 해도 동일한
# Designated Requirement가 유지되어 Keychain ACL("Always Allow")이 계속 유효.
# 없으면 ad-hoc(서명 hash가 빌드마다 바뀜 → Keychain이 매번 새 앱으로 인식).
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Apple Development:" \
    | head -1 \
    | awk -F'"' '{print $2}')

if [ -n "$IDENTITY" ]; then
    echo "▶ Signing with: $IDENTITY"
    codesign --force --deep --sign "$IDENTITY" --options runtime "$APP"
else
    echo "▶ Apple Development 인증서 없음 → ad-hoc 서명 (Keychain 매번 다시 물음)"
    codesign --force --deep --sign - "$APP"
fi

echo "✅ Built: $(pwd)/$APP"
echo ""
echo "실행: open $(pwd)/$APP"
echo "/Applications/로 옮기려면: mv $APP /Applications/"
