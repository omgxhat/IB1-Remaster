#!/bin/zsh
# sign.sh <source .app> <output dir> [bundle id] [display name]
# Clones the app (APFS copy-on-write, no extra disk), sets a bundle id we own,
# strips the old App Store leftovers, embeds the team wildcard profile and signs.
set -euo pipefail
SRC=$1; OUT=$2; BID=${3:-com.example.ib1}; NAME=${4:-IB1 Test}
TEAM=TEAMID
IDENT=SIGNING-CERTIFICATE-SHA1
PROFILE="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/PROFILE-ID.mobileprovision"
# Signed in a side folder and moved into place only once the whole app checks out (Infinity Blade 2's FIXES.md 46,
# 3 November 2026: a build stopped partway left an app whose game program kept a broken signature; FIXES.md 92 here).
FINAL="$OUT/SwordGame.app"; APP="$OUT/.part/SwordGame.app"     # the bundle keeps its .app name for codesign
rm -rf "$OUT/.part"; mkdir -p "$OUT/.part"
cp -cR "$SRC" "$APP"
rm -rf "$APP/_CodeSignature" "$APP/SC_Info"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BID" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $NAME" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $NAME" "$APP/Info.plist"
cp "$PROFILE" "$APP/embedded.mobileprovision"
cat > "$OUT/ent.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>$TEAM.$BID</string>
<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
<key>get-task-allow</key><true/>
<key>keychain-access-groups</key><array><string>$TEAM.$BID</string></array>
</dict></plist>
PL
# sign any nested code first (dylibs we may inject later), then the app
find "$APP" -name '*.dylib' -print0 | xargs -0 -I{} codesign -f -s $IDENT {} 2>/dev/null || true
codesign -f -s $IDENT --entitlements "$OUT/ent.plist" "$APP"
codesign --verify --deep --strict "$APP" || { echo "SIGNING FAILED: $APP left as it is, $FINAL not replaced"; exit 1; }
rm -rf "$FINAL"; mv "$APP" "$FINAL"; rmdir "$OUT/.part"
echo "signed OK: $FINAL ($BID)"
