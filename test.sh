#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
cd "$PROJECT_DIR"
PROJECT_CACHE_KEY=$(print -rn -- "$PROJECT_DIR" | cksum)
MODULE_CACHE="$PROJECT_DIR/build/module-cache/${PROJECT_CACHE_KEY%% *}"
mkdir -p "$MODULE_CACHE"
xcrun swiftc -swift-version 5 -module-cache-path "$MODULE_CACHE" \
    Sources/EdgePolicy.swift Sources/ZoomGestureFilter.swift Tests/main.swift -o build/EdgePolicyTests
build/EdgePolicyTests
