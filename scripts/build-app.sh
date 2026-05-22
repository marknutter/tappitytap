#!/usr/bin/env bash
set -euo pipefail

# Build a relocatable tappitytap.app bundle from the SPM products. The bundle
# embeds both the menu-bar app and the privileged helper, plus a launchd
# property list that SMAppService will pick up when the user clicks
# "Install Helper" from the menu. Ad-hoc signed for local install — for
# distribution you'd swap the codesign call to use a Developer ID identity
# and then notarize.

cd "$(dirname "$0")/.."

APP="dist/tappitytap.app"
BUNDLE_ID="com.marknutter.tappitytap"
HELPER_LABEL="com.marknutter.tappitytap.helper"

echo "==> Building release binaries"
swift build -c release

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp .build/release/tappitytap        "$APP/Contents/MacOS/tappitytap"
cp .build/release/tappitytap-helper "$APP/Contents/MacOS/tappitytap-helper"

cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>tappitytap</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>tappitytap</string>
    <key>CFBundleDisplayName</key>
    <string>tappitytap</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>0.1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Note on the LaunchDaemon: the app generates a plist on demand at install
# time (Coordinator.installDaemon) with an absolute Program path. SMAppService
# would let us ship a BundleProgram-relative plist inside the bundle, but it
# requires a Developer ID signature — out of scope for an ad-hoc build.

echo "==> Ad-hoc signing"
# Sign the helper first (inner content), then the whole bundle.
codesign --force --options runtime --sign - "$APP/Contents/MacOS/tappitytap-helper"
codesign --force --options runtime --sign - "$APP/Contents/MacOS/tappitytap"
codesign --force --deep --options runtime --sign - "$APP"

echo
echo "Built $APP"
echo
echo "To install: drag dist/tappitytap.app to /Applications, then open it."
echo "  cp -R $APP /Applications/ && open /Applications/tappitytap.app"
echo
echo "After launch, click the waveform icon in the menu bar and choose"
echo "  'Install Helper' — macOS will prompt you to approve it in"
echo "  System Settings > Login Items & Extensions."
