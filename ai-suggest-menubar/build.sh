#!/usr/bin/env bash
# Builds ai-suggest-menubar and packages it into ai-suggest-menubar.app.
#
# Accessibility (TCC) permission is significantly more reliable when
# granted to a real .app bundle than to a bare command-line executable —
# bare-executable grants were observed to silently fail to take effect
# (AXIsProcessTrusted stayed false across repeated remove/re-add cycles in
# System Settings) during development of the overlay feature. Wrapping in
# a minimal bundle (Info.plist + LSUIElement) and re-signing at the bundle
# level fixed it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="ai-suggest-menubar.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ai-suggest-menubar "$APP/Contents/MacOS/ai-suggest-menubar"

# SPM's generated resource_bundle_accessor.swift (Bundle.module) looks for
# this .bundle directly inside Bundle.main.bundleURL — i.e. the .app's own
# top level, not Contents/Resources — so that's where it has to land for
# the brand-icon SVGs (Sources/ai-suggest-menubar/Resources/*.svg) to load
# once this is a real double-clickable .app instead of a bare binary run
# straight out of .build/.
RESOURCE_BUNDLE=".build/release/ai-suggest-menubar_ai-suggest-menubar.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    rm -rf "$APP/ai-suggest-menubar_ai-suggest-menubar.bundle"
    cp -R "$RESOURCE_BUNDLE" "$APP/ai-suggest-menubar_ai-suggest-menubar.bundle"
fi

# Re-sign at the bundle level (ad-hoc — no Developer ID needed for local
# use) so the bundle's own code identity, not just the loose binary's, is
# what Accessibility permission gets granted to.
codesign --force --deep --sign - "$APP"

echo "Built $APP — run it with: open \"$APP\""
