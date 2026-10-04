#!/bin/bash
# Compile real production code with isolated, test-only service management.
# This runner does not install/launch SysPulse or change its preferences/login item.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_BUILD="${SYSPULSE_TEST_BUILD_DIR:-$PROJECT_ROOT/build/regression}"
TEST_TARGET="$(uname -m)-apple-macosx14.0"
mkdir -p "$TEST_BUILD/modulecache"

swiftc -swift-version 5 -target "$TEST_TARGET" -warnings-as-errors -module-cache-path "$TEST_BUILD/modulecache" \
    -emit-library -emit-module -module-name ServiceManagement \
    "$PROJECT_ROOT/Tools/Regression/ServiceManagementMock.swift" \
    -emit-module-path "$TEST_BUILD/ServiceManagement.swiftmodule" \
    -o "$TEST_BUILD/libServiceManagement.dylib"

SOURCE_FILES=(
    Monitors.swift SystemMonitor.swift Preferences.swift LaunchAtLogin.swift
    Formatting.swift MenuBarImage.swift PanelAnchorAnimation.swift
    DashboardView.swift StatusItemController.swift
)
SOURCE_ARGS=()
for source in "${SOURCE_FILES[@]}"; do
    SOURCE_ARGS+=("$PROJECT_ROOT/Sources/SysPulse/$source")
done

swiftc -O -swift-version 5 -target "$TEST_TARGET" -warnings-as-errors -module-cache-path "$TEST_BUILD/modulecache" \
    -framework AppKit -framework SwiftUI -framework IOKit \
    -I "$TEST_BUILD" -L "$TEST_BUILD" -lServiceManagement \
    -Xlinker -rpath -Xlinker "$TEST_BUILD" \
    "${SOURCE_ARGS[@]}" "$PROJECT_ROOT/Tools/Regression/RegressionTests.swift" \
    -o "$TEST_BUILD/RegressionTests"

"$TEST_BUILD/RegressionTests"
python3 "$PROJECT_ROOT/Tools/Regression/ControllerStateTests.py" "$TEST_BUILD/controller"
