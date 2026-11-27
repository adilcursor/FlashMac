#!/bin/zsh
# Builds FlashMac.app into ./build, replaces /Applications/FlashMac.app with it and relaunches it.
# Also writes build/FlashMac.zip to copy to other Macs.
# Usage: Scripts/build.sh [--no-install]
set -euo pipefail
cd "${0:A:h}/.."
ROOT=$PWD
NAME="FlashMac"
BUNDLE_ID="local.flashmac.app"
APP="$ROOT/build/$NAME.app"
rm -rf "$ROOT/build/Mole.app" "$ROOT/build/Mole.zip"   # old name

# Universal binary: runs on Apple Silicon and Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/MoleApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"

# Bundle a copy of Mole (MIT licensed) so the app works on Macs without `mo` installed.
MO_BIN="$(command -v mo || true)"
if [[ -n "$MO_BIN" ]]; then
  MO_REAL="${MO_BIN:A}"                 # resolve symlinks
  MO_ROOT="${MO_REAL:h:h}"              # .../Cellar/mole/<version>
  if [[ -d "$MO_ROOT/libexec" && -f "$MO_ROOT/bin/mole" ]]; then
    DEST="$APP/Contents/Resources/mole"
    mkdir -p "$DEST/bin"
    cp -R "$MO_ROOT/libexec" "$DEST/libexec"
    cp "$MO_ROOT/bin/mole" "$DEST/bin/mole"
    [[ -f "$MO_ROOT/LICENSE" ]] && cp "$MO_ROOT/LICENSE" "$DEST/LICENSE"
    # Homebrew hardcodes its Cellar path; make it relative to the bundle.
    sed -i '' 's|^SCRIPT_DIR=.*$|SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../libexec" \&\& pwd)"|' "$DEST/bin/mole"
    chmod -R u+w "$DEST"                 # Homebrew files are read-only
    chmod +x "$DEST/bin/mole"
    echo "Bundled Mole from $MO_ROOT"
  else
    echo "warning: couldn't find Mole's files next to $MO_REAL; not bundling" >&2
  fi
else
  echo "warning: mo not installed; app will need mo on the target Mac" >&2
fi

# Icon
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swift Scripts/make_icon.swift "$ROOT/build/icon_1024.png" 1024
for s in 16 32 128 256 512; do
  sips -z $s $s "$ROOT/build/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$ROOT/build/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will launch it locally.
# Strip extended attributes first so the zip carries no hidden ._ metadata files
# (they break the signature when the zip is opened with the command-line unzip tool).
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
echo "Built $APP"

# Zip for copying to another Mac (keeps permissions and the signature).
rm -f "$ROOT/build/$NAME.zip"
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP" "$ROOT/build/$NAME.zip"
echo "Wrote $ROOT/build/$NAME.zip"

if [[ "${1:-}" != "--no-install" ]]; then
  # Quit running copies (current and the old "Mole" build), replace the installed app, relaunch.
  for id in "$BUNDLE_ID" local.moleapp.gui; do
    osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
  done
  for _ in {1..20}; do pgrep -x "$NAME" >/dev/null || pgrep -x Mole >/dev/null || break; sleep 0.25; done
  pkill -x "$NAME" 2>/dev/null || true
  pkill -x Mole 2>/dev/null || true
  rm -rf "/Applications/$NAME.app" /Applications/Mole.app
  ditto "$APP" "/Applications/$NAME.app"
  echo "Installed /Applications/$NAME.app"
  open "/Applications/$NAME.app"
fi
