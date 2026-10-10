#!/bin/bash
# Render real SwiftUI panels and exercise controls using isolated preferences/login-item mock.
# Does not install SysPulse or alter its real preferences; briefly opens preview windows.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROBE_BUILD="$PROJECT_ROOT/build/panel-probe-verification"
PROBE_TARGET="$(uname -m)-apple-macosx14.0"
mkdir -p "$PROBE_BUILD/modulecache"
swiftc -swift-version 5 -target "$PROBE_TARGET" -warnings-as-errors \
    -module-cache-path "$PROBE_BUILD/modulecache" \
    -emit-library -emit-module -module-name ServiceManagement \
    "$PROJECT_ROOT/Tools/Regression/ServiceManagementMock.swift" \
    -emit-module-path "$PROBE_BUILD/ServiceManagement.swiftmodule" \
    -o "$PROBE_BUILD/libServiceManagement.dylib"
SOURCE_ARGS=()
for source in Monitors SystemMonitor Preferences LaunchAtLogin Formatting MenuBarImage PanelAnchorAnimation PanelDetailAnimation PanelPresentationAnimation DashboardView DeviceInformationCard StatusItemController SingleInstance; do
    SOURCE_ARGS+=("$PROJECT_ROOT/Sources/SysPulse/$source.swift")
done
swiftc -O -swift-version 5 -target "$PROBE_TARGET" -warnings-as-errors \
    -module-cache-path "$PROBE_BUILD/modulecache" \
    -framework AppKit -framework SwiftUI -framework IOKit \
    -I "$PROBE_BUILD" -L "$PROBE_BUILD" -lServiceManagement \
    -Xlinker -rpath -Xlinker "$PROBE_BUILD" \
    "${SOURCE_ARGS[@]}" "$PROJECT_ROOT/Tools/PanelProbe/NativeVerification.swift" "$PROJECT_ROOT/Tools/PanelProbe/main.swift" \
    -o "$PROBE_BUILD/PanelProbe"
mkdir -p "$PROBE_BUILD/isolated-home"
CFFIXED_USER_HOME="$PROBE_BUILD/isolated-home" "$PROBE_BUILD/PanelProbe" "$PROBE_BUILD/preview" --popover "$@"
