#!/bin/bash
# ClaudeUsageBar.app을 배포용 .dmg로 패키징.
# 선행: ./make_app.sh (서명된 ClaudeUsageBar.app 생성) 이 먼저 실행돼 있어야 함.
# 사용: ./make_dmg.sh
# 결과물: ./ClaudeUsageBar_<version>_aarch64.dmg  (Developer ID 서명 시 dmg도 서명)

set -euo pipefail

cd "$(dirname "$0")"

APP="ClaudeUsageBar.app"
if [ ! -d "$APP" ]; then
    echo "✗ $APP 가 없습니다. 먼저 ./make_app.sh 를 실행하세요." >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="ClaudeUsageBar_${VERSION}_aarch64.dmg"
VOLNAME="ClaudeUsageBar"

echo "▶ Packaging $APP (v$VERSION) → $DMG"
rm -f "$DMG"

# 드래그-투-인스톨 레이아웃: .app + /Applications 심볼릭 링크를 스테이징에 모아 압축 dmg 생성.
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# UDZO(zlib 압축). -srcfolder 방식이라 별도 attach/detach 없이 한 번에 생성.
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG"

# dmg 자체도 Developer ID로 서명(있을 때만). 배포 dmg 무결성 + Gatekeeper 친화.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application:" \
    | head -1 \
    | awk -F'"' '{print $2}')

if [ -n "$IDENTITY" ]; then
    echo "▶ Signing dmg with: $IDENTITY"
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    codesign --verify --verbose=2 "$DMG"
else
    echo "▶ Developer ID 인증서 없음 → dmg 미서명(로컬 확인용)."
fi

echo "✅ Built: $(pwd)/$DMG"
echo ""
echo "검증: spctl -a -vvv -t open --context context:primary-signature $DMG"
echo "배포: gh release upload v${VERSION} $DMG"
