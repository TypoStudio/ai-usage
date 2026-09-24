#!/bin/bash
# AIUsage .app + dmg 생성. 위젯 익스텐션·App Group 때문에 ad-hoc 이 아닌 팀 서명이 필요하다.
#   AIUSAGE_TEAM      팀 ID (없으면 키체인의 첫 Apple Development 인증서에서 읽는다)
#   SIGN_IDENTITY     서명 ID (기본 "Apple Development", 배포 시 "Developer ID Application")
#   INSTALL=1         빌드 후 /Applications 에 설치하고 실행
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development}"
if [ -z "${AIUSAGE_TEAM:-}" ]; then
  # 개인 키가 있는 유효한 서명 ID 중 첫 번째의 인증서에서 팀(OU)을 읽는다
  HASH=$(security find-identity -v -p codesigning | grep "\"$SIGN_IDENTITY" | head -1 | awk '{print $2}')
  AIUSAGE_TEAM=$(security find-certificate -a -c "$SIGN_IDENTITY" -Z -p 2>/dev/null \
    | awk -v h="$HASH" '/^SHA-1 hash:/ {keep = ($3 == h)} keep && !/^SHA-/' \
    | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')
fi
[ -n "$AIUSAGE_TEAM" ] || { echo "팀 ID를 찾지 못했습니다. AIUSAGE_TEAM=XXXXXXXXXX 로 지정하세요." >&2; exit 1; }
export AIUSAGE_TEAM

BUILD_FILE="scripts/.build-number"
BUILD=$(( $(cat "$BUILD_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$BUILD" > "$BUILD_FILE"
echo "▶ 버전 $VERSION ($BUILD), 팀 $AIUSAGE_TEAM, 서명 \"$SIGN_IDENTITY\""

echo "▶ 코어 테스트..."
(cd Packages/AIUsageCore && swift test -q)

echo "▶ Xcode 프로젝트 생성..."
xcodegen generate --quiet

echo "▶ release 빌드..."
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release \
  -derivedDataPath build/dd CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" -quiet build

APP="build/AIUsage.app"
rm -rf "$APP"
ditto build/dd/Build/Products/Release/AIUsage.app "$APP"
codesign --verify --deep --strict "$APP"

DMG="build/AIUsage-${VERSION}.dmg"
echo "▶ dmg: $DMG"
rm -f "$DMG"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/AIUsage.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "AI Usage" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# 빌드 폴더 사본을 LaunchServices 에서 뺀다. 같은 번들 ID 의 더 높은 버전이 등록돼 있으면
# 위젯 데몬(chronod)이 그 기록을 기준으로 삼아 설치본 위젯을 "Bundle version did not match" 로 못 그린다.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for copy in build/dd/Build/Products/*/AIUsage.app "$APP"; do
  [ -d "$copy" ] && "$LSREGISTER" -u "$PWD/$copy" 2>/dev/null || true
done

if [ "${INSTALL:-0}" = "1" ]; then
  echo "▶ /Applications 설치"
  pkill -x AIUsage 2>/dev/null || true
  rm -rf /Applications/AIUsage.app
  ditto "$APP" /Applications/AIUsage.app
  # 아이콘·이름 캐시 갱신 — 안 하면 이전 설치본의 빈 아이콘이 남는다
  touch /Applications/AIUsage.app
  "$LSREGISTER" -f -R /Applications/AIUsage.app
  open /Applications/AIUsage.app
fi
echo "✓ 완료"
