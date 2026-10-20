#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
cd "$PROJECT_DIR"
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PROJECT_DIR/build/module-cache" \
    Sources/EdgePolicy.swift Tests/main.swift -o build/EdgePolicyTests
build/EdgePolicyTests
