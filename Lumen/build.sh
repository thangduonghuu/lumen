#!/usr/bin/env bash
# Builds Lumen and packages it into Lumen.app.
#
# Accessibility (TCC) permission is significantly more reliable when
# granted to a real .app bundle than to a bare command-line executable —
# bare-executable grants were observed to silently fail to take effect
# (AXIsProcessTrusted stayed false across repeated remove/re-add cycles in
# System Settings) during development of the overlay feature. Wrapping in
# a minimal bundle (Info.plist + LSUIElement) and re-signing at the bundle
# level fixed it.
#
# Ad-hoc signing (no paid Apple Developer ID here) means every rebuild
# produces a fresh code-signature hash — macOS's Accessibility grant is
# tied to that exact signature, so each rebuild silently invalidates
# whatever grant a previous build had. After running this script, re-grant
# Accessibility permission in System Settings → Privacy & Security →
# Accessibility if positioning stops working.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Lumen.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Lumen "$APP/Contents/MacOS/Lumen"

# Regenerated on every build rather than hand-maintained separately, so the
# bundle is fully reproducible from this script alone.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Lumen</string>
	<key>CFBundleIdentifier</key>
	<string>com.lumen.menubar</string>
	<key>CFBundleName</key>
	<string>Lumen</string>
	<key>CFBundleIconFile</key>
	<string>Lumen.icns</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# App icon (Finder, Dock-less-but-still-visible-in-System-Settings, the
# Accessibility permission list, etc). The source .icns lives under
# Sources/Lumen/Resources/ alongside the brand SVGs for convenience, but
# CFBundleIconFile requires it directly in Contents/Resources/ — the SPM
# resource-bundle mechanism the SVGs use (nested Lumen_Lumen.bundle, see
# below) doesn't apply to the bundle's own icon.
mkdir -p "$APP/Contents/Resources"
cp Sources/Lumen/Resources/Lumen.icns "$APP/Contents/Resources/Lumen.icns"

# SPM's generated resource_bundle_accessor.swift (Bundle.module) looks for
# this .bundle directly inside Bundle.main.bundleURL — i.e. the .app's own
# top level, not Contents/Resources — so that's where it has to land for
# the brand-icon SVGs (Sources/Lumen/Resources/*.svg) to load once this is
# a real double-clickable .app instead of a bare binary run straight out
# of .build/.
RESOURCE_BUNDLE=".build/release/Lumen_Lumen.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    rm -rf "$APP/Lumen_Lumen.bundle"
    cp -R "$RESOURCE_BUNDLE" "$APP/Lumen_Lumen.bundle"
fi

# Re-sign at the bundle level (ad-hoc — no Developer ID needed for local
# use) so the bundle's own code identity, not just the loose binary's, is
# what Accessibility permission gets granted to.
codesign --force --deep --sign - "$APP"

echo "Built $APP — run it with: open \"$APP\""
