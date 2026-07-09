#!/usr/bin/env bash
#
# Construit "Potof Toolkit.app" (bundle macOS) à partir du package Swift et
# l'installe dans un dossier indexé par Spotlight.
#
# Usage :
#   ./Scripts/build-app.sh                 # installe dans ~/Applications
#   ./Scripts/build-app.sh /Applications   # installe ailleurs (droits requis)
#
set -euo pipefail

APP_NAME="Potof Toolkit"
EXE_NAME="potof-toolkit"
BUNDLE_ID="com.potof.potof-toolkit"
INSTALL_DIR="${1:-$HOME/Applications}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▶︎ Compilation release…"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"

APP="$INSTALL_DIR/$APP_NAME.app"
echo "▶︎ Assemblage du bundle : $APP"
mkdir -p "$INSTALL_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1. Exécutable
cp "$BIN_PATH/$EXE_NAME" "$APP/Contents/MacOS/$EXE_NAME"

# 2. Resource bundle(s) SPM, emplacement standard signable (Contents/Resources/).
#    NB : l'app bundlée n'utilise PAS Bundle.module (AppDelegate.applyDockIcon en
#    fait l'impasse en mode .app, l'icône venant du .icns) — cf. l'accessor SwiftPM
#    qui, lui, chercherait le bundle à la racine du .app, hors structure signable.
for b in "$BIN_PATH"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

# 3. Icône .icns depuis le PNG 1024
ICON_SRC="$ROOT/Sources/potof-toolkit/Resources/AppIcon.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    s2=$((size * 2))
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png"      >/dev/null
    sips -z "$s2"   "$s2"   "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png"   >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 4. Info.plist
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$EXE_NAME</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1.1</string>
    <key>CFBundleVersion</key>           <string>3</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

echo "APPL????" > "$APP/Contents/PkgInfo"

# 5. Signature ad-hoc (identité stable pour TCC/Automation, sans certificat)
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign ad-hoc ignoré)"

# 6. Enregistrement Launch Services (Spotlight / open -a)
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" || true

echo "✅ Installé : $APP"
echo "   Cherche « Potof » avec Cmd+Espace, ou : open -a \"$APP_NAME\""
