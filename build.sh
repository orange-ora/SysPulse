#!/bin/bash
# 构建 SysPulse：默认只安装到 /Applications/SysPulse.app。
# --local 仅输出 dist/SysPulse.app.zip，不退出或安装应用。
# --no-launch 安装后不启动。临时展开的应用只存在于 .noindex 目录。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SysPulse"
BUILD="build"
INSTALL_DIR="/Applications"
APP_DIR="$INSTALL_DIR/$APP_NAME.app"
LOCAL_ONLY=0
LAUNCH=1
for arg in "$@"; do
    case "$arg" in
        --local) LOCAL_ONLY=1 ;;
        --no-launch) LAUNCH=0 ;;
        *) echo "未知参数: $arg" >&2; exit 1 ;;
    esac
done

if [ "$LOCAL_ONLY" = 0 ]; then
    if [ ! -w "$INSTALL_DIR" ]; then
        echo "无法写入 $INSTALL_DIR；安装停止。可用 --local 生成压缩包。" >&2
        exit 1
    fi
    if [ -L "$APP_DIR" ] || { [ -e "$APP_DIR" ] && [ ! -d "$APP_DIR" ]; }; then
        echo "正式安装路径不是普通应用目录：$APP_DIR" >&2
        exit 1
    fi
    TEMP_ROOT=$(mktemp -d "$INSTALL_DIR/.SysPulse-build.XXXXXX")
else
    TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/SysPulse-build.XXXXXX")
fi
# macOS BSD mktemp 只随机化末尾 X；先重命名空目录，再放入任何 .app。
if [ -e "$TEMP_ROOT.noindex" ] || ! mv "$TEMP_ROOT" "$TEMP_ROOT.noindex"; then
    rmdir "$TEMP_ROOT"
    echo "无法建立唯一的 .noindex 暂存目录。" >&2
    exit 1
fi
TEMP_ROOT="$TEMP_ROOT.noindex"
CANDIDATE="$TEMP_ROOT/$APP_NAME.app"
PREVIOUS="$TEMP_ROOT/previous/$APP_NAME.app"
RUNNING_MARKER="$TEMP_ROOT/was-running"
OLD_MOVED=0
NEW_INSTALLED=0
BACKUP_ARCHIVE=""

cleanup() {
    local result=$?
    trap - EXIT HUP INT TERM
    if [ "$result" != 0 ] && [ "$LOCAL_ONLY" = 0 ]; then
        if [ "$NEW_INSTALLED" = 1 ]; then
            rm -rf "$APP_DIR"
        fi
        if [ "$OLD_MOVED" = 1 ]; then
            if ! mv "$PREVIOUS" "$APP_DIR"; then
                echo "恢复旧版失败；旧版仍保留于 $PREVIOUS，压缩备份：$BACKUP_ARCHIVE" >&2
                exit "$result"
            fi
            echo "安装失败，已恢复旧版：$APP_DIR" >&2
        fi
        if [ -f "$RUNNING_MARKER" ] && [ -d "$APP_DIR" ]; then
            open "$APP_DIR" || echo "请手动启动已恢复的 $APP_DIR" >&2
        fi
    fi
    rm -rf "$TEMP_ROOT"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

export CLANG_MODULE_CACHE_PATH="$PWD/$BUILD/modulecache"
export SWIFT_MODULECACHE_PATH="$PWD/$BUILD/modulecache"
mkdir -p "$BUILD/modulecache"
COMMON_FLAGS=(
    -O -wmo -swift-version 5
    -module-cache-path "$PWD/$BUILD/modulecache"
    -framework IOKit -framework AppKit -framework SwiftUI -framework ServiceManagement
)
build_arch() {
    swiftc "${COMMON_FLAGS[@]}" -target "$1-apple-macosx14.0" \
        -o "$BUILD/$APP_NAME-$1" Sources/SysPulse/*.swift
}
echo "==> 编译"
rm -f "$BUILD/$APP_NAME" "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
if build_arch arm64 && build_arch x86_64; then
    lipo -create -output "$BUILD/$APP_NAME" "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
    echo "    通用二进制 (arm64 + x86_64)"
else
    echo "    双架构构建不可用，改用 arm64"
    build_arch arm64
    mv "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME"
fi
if [ ! -f Resources/AppIcon.icns ]; then
    swift Tools/MakeIcon.swift
fi

mkdir -p "$CANDIDATE/Contents/MacOS" "$CANDIDATE/Contents/Resources"
cp "$BUILD/$APP_NAME" "$CANDIDATE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$CANDIDATE/Contents/Info.plist"
cp Resources/AppIcon.icns "$CANDIDATE/Contents/Resources/AppIcon.icns"
BUILD_REV="unknown"; BUILD_COUNT=0; BUILD_DIRTY=""
if git rev-parse --git-dir >/dev/null 2>&1; then
    BUILD_REV=$(git rev-parse --short HEAD)
    BUILD_COUNT=$(git rev-list --count HEAD)
    if ! git diff --quiet || ! git diff --cached --quiet; then BUILD_DIRTY="-dirty"; fi
fi
BUILD_STAMP="${BUILD_REV}${BUILD_DIRTY}@$(date '+%Y%m%d-%H%M%S')"
PLIST="$CANDIDATE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_COUNT" "$PLIST"
if ! /usr/libexec/PlistBuddy -c "Set :SysPulseBuildStamp $BUILD_STAMP" "$PLIST" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :SysPulseBuildStamp string $BUILD_STAMP" "$PLIST"
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
case "$VERSION" in
    ""|*[!0-9.]*|.*|*..*) echo "无效应用版本：$VERSION" >&2; exit 1 ;;
esac
echo "    构建指纹: $BUILD_STAMP (版本 ${VERSION}，build ${BUILD_COUNT})"
codesign --force --deep --sign - "$CANDIDATE"
codesign --verify --all-architectures --deep --strict "$CANDIDATE"

if [ "$LOCAL_ONLY" = 1 ]; then
    mkdir -p dist
    ARCHIVE="$TEMP_ROOT/$APP_NAME-$VERSION.app.zip"
    ditto -c -k --sequesterRsrc --keepParent "$CANDIDATE" "$ARCHIVE"
    mv -f "$ARCHIVE" "dist/$APP_NAME.app.zip"
    echo "==> 完成: dist/$APP_NAME.app.zip（未安装、未退出正在运行的应用）"
    exit 0
fi

# 精准匹配正式 bundle 与可执行路径；其他目录中的同名应用不受影响。
cat > "$TEMP_ROOT/StopInstalled.swift" <<'SWIFT'
import AppKit
import Foundation
let installed = URL(fileURLWithPath: "/Applications/SysPulse.app").standardizedFileURL
let executable = installed.appendingPathComponent("Contents/MacOS/SysPulse")
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.syspulse").filter {
    $0.bundleURL?.standardizedFileURL == installed && $0.executableURL?.standardizedFileURL == executable
}
if !apps.isEmpty {
    try Data().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    for app in apps {
        guard app.terminate() else {
            FileHandle.standardError.write(Data("正式应用拒绝退出，停止安装。\n".utf8))
            exit(1)
        }
    }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline && apps.contains(where: { !$0.isTerminated }) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard apps.allSatisfy({ $0.isTerminated }) else {
        FileHandle.standardError.write(Data("正式应用未及时退出，停止安装。\n".utf8))
        exit(1)
    }
}
SWIFT
swiftc -O -swift-version 5 -module-cache-path "$PWD/$BUILD/modulecache" \
    -framework AppKit "$TEMP_ROOT/StopInstalled.swift" -o "$TEMP_ROOT/stop-installed"

# 先保存并回读压缩备份，再退出旧实例；旧展开包只暂存于 .noindex，失败可回滚。
if [ -d "$APP_DIR" ]; then
    mkdir -p Backups "$TEMP_ROOT/backup-check" "$TEMP_ROOT/previous"
    BACKUP_ARCHIVE="$PWD/Backups/$APP_NAME-before-${BUILD_STAMP}-$$.app.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$TEMP_ROOT/previous.app.zip"
    ditto -x -k "$TEMP_ROOT/previous.app.zip" "$TEMP_ROOT/backup-check"
    cmp "$APP_DIR/Contents/MacOS/$APP_NAME" "$TEMP_ROOT/backup-check/$APP_NAME.app/Contents/MacOS/$APP_NAME"
    cmp "$APP_DIR/Contents/Info.plist" "$TEMP_ROOT/backup-check/$APP_NAME.app/Contents/Info.plist"
    mv "$TEMP_ROOT/previous.app.zip" "$BACKUP_ARCHIVE"
    rm -rf "$TEMP_ROOT/backup-check"
fi
"$TEMP_ROOT/stop-installed" "$RUNNING_MARKER"
if [ -d "$APP_DIR" ]; then
    mv "$APP_DIR" "$PREVIOUS"
    OLD_MOVED=1
fi
mv "$CANDIDATE" "$APP_DIR"
NEW_INSTALLED=1
codesign --verify --all-architectures --deep --strict "$APP_DIR"
if [ "$LAUNCH" = 1 ]; then open "$APP_DIR"; fi
# 成功后只留下正式安装包与压缩备份；EXIT trap 删除临时展开旧包。
echo "==> 完成: $APP_DIR"
if [ -n "$BACKUP_ARCHIVE" ]; then echo "    旧版压缩备份: $BACKUP_ARCHIVE"; fi
