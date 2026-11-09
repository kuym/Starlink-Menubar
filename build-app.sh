#!/bin/zsh
# Builds a release binary and wraps it in build/StarlinkMenuBar.app (ad-hoc signed).
set -euo pipefail
cd "${0:A:h}"
swift build -c release
APP=build/StarlinkMenuBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/StarlinkMenuBar "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP  —  open it with: open $APP"
