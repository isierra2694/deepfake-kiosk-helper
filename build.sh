#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
cd "$PROJECT_DIR"
APP_DIR="$PROJECT_DIR/build/Kiosk Edge Guard.app"
# Swift module caches contain absolute paths. Keep a separate cache after a move.
PROJECT_CACHE_KEY=$(print -rn -- "$PROJECT_DIR" | cksum)
MODULE_CACHE="$PROJECT_DIR/build/module-cache/${PROJECT_CACHE_KEY%% *}"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$MODULE_CACHE"
# ARCHS="arm64 x86_64" ./build.sh makes a universal app for a different event Mac.
ARCH_LIST=( ${=ARCHS:-$(uname -m)} )
BINARIES=()
for APP_ARCH in "${ARCH_LIST[@]}"; do
    APP_BINARY="$PROJECT_DIR/build/KioskEdgeGuard-$APP_ARCH"
    xcrun swiftc -swift-version 5 -O -target "$APP_ARCH-apple-macosx13.0" \
        -module-cache-path "$MODULE_CACHE" \
        -framework AppKit -framework ApplicationServices -framework Carbon -framework ColorSync \
        Sources/EdgePolicy.swift Sources/ZoomGestureFilter.swift Sources/main.swift -o "$APP_BINARY"
    BINARIES+=("$APP_BINARY")
done
if (( ${#BINARIES[@]} > 1 )); then
    xcrun lipo -create "${BINARIES[@]}" -output "$APP_DIR/Contents/MacOS/KioskEdgeGuard"
else
    cp "${BINARIES[1]}" "$APP_DIR/Contents/MacOS/KioskEdgeGuard"
fi
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
codesign --force --sign "${SIGNING_IDENTITY:--}" --identifier local.kiosk.edgeguard "$APP_DIR"
print -r -- "Built: $APP_DIR"
