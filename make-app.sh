#!/bin/zsh
# Produit Claudette.app, un bundle .app minimal nécessaire pour que
# UNUserNotificationCenter et SMAppService aient un CFBundleIdentifier.
# Génère aussi l'icône d'app via Claudette --generate-icon + iconutil.
#
# Usage: ./make-app.sh [--install]
#   --install : copie le bundle dans /Applications après build.

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="release"
APP="Claudette.app"
BUNDLE_ID="dev.claudette.app"
VERSION="0.5.13"
BUILD="18"

echo "▶ Building $CONFIG…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Claudette"
[ -x "$BIN" ] || { echo "✗ binaire introuvable: $BIN"; exit 1; }

echo "▶ Packaging $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Claudette"

# Copie tous les resource bundles SPM (Claudette_Claudette.bundle + deps).
for b in .build/$CONFIG/*.bundle; do
    [ -e "$b" ] || continue
    cp -R "$b" "$APP/Contents/Resources/"
done

# ─── icône ──────────────────────────────────────────────────────────────────
echo "▶ Génération de l'icône .icns…"
ICON_TMP=$(mktemp -d)
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

# Claudette se rend lui-même en PNG 1024×1024 (mode CLI).
"$BIN" --generate-icon "$ICONSET/icon_512x512@2x.png" || {
    echo "✗ rendu icône échoué"; exit 1;
}

# Tailles requises par iconutil.
sips -z 16   16   "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_16x16.png"        >/dev/null
sips -z 32   32   "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_16x16@2x.png"     >/dev/null
sips -z 32   32   "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_32x32.png"        >/dev/null
sips -z 64   64   "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_32x32@2x.png"     >/dev/null
sips -z 128  128  "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_128x128.png"      >/dev/null
sips -z 256  256  "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_128x128@2x.png"   >/dev/null
sips -z 256  256  "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_256x256.png"      >/dev/null
sips -z 512  512  "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_256x256@2x.png"   >/dev/null
sips -z 512  512  "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_512x512.png"      >/dev/null

iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"

# ─── Info.plist ────────────────────────────────────────────────────────────
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Claudette</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>Claudette</string>
    <key>CFBundleDisplayName</key>
    <string>Claudette</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Claudette pilote Ghostty via AppleScript pour énumérer les sessions et basculer sur la bonne fenêtre.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Signature ad-hoc : suffit pour que macOS accepte de lancer le bundle local.
codesign --force --deep --sign - "$APP" >/dev/null

# Rafraichit le cache d'icônes pour que Finder voie l'icône.
touch "$APP"

# Enregistre le bundle auprès de LaunchServices. Sans ça, UNUserNotificationCenter
# refuse les notifs ("bundle proxy not found").
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$APP" 2>/dev/null || true

echo "✓ $APP prêt."
echo "  Lancer : open $(pwd)/$APP"

# ─── DMG (release artifact) ────────────────────────────────────────────────
# Produit un Claudette.dmg drag-and-drop : icône Claudette.app à côté d'un
# alias Applications. Utilise hdiutil natif, pas de dépendance Homebrew.
DMG="Claudette.dmg"
echo "▶ Empaquetage $DMG…"
rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
    -volname "Claudette" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✓ $DMG prêt ($(du -h "$DMG" | cut -f1))."

if [ "${1:-}" = "--install" ]; then
    echo "▶ Installation dans /Applications…"
    rm -rf "/Applications/$APP"
    cp -R "$APP" "/Applications/"
    echo "✓ /Applications/$APP installé."
    echo "  Lancer : open /Applications/$APP"
fi
