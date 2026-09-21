#!/bin/bash
# 构建 SysPulse 并安装到 /Applications（纯 swiftc，不依赖 Xcode 工程）
#
#   ./build.sh              编译 + 安装到 /Applications/SysPulse.app（唯一副本）
#   ./build.sh --local      只在本目录打包到 dist/，不安装
#   ./build.sh --no-launch  安装但不自动启动
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="SysPulse"
BUILD="build"
INSTALL_DIR="/Applications"

LOCAL_ONLY=0
LAUNCH=1
for arg in "$@"; do
    case "$arg" in
        --local)     LOCAL_ONLY=1 ;;
        --no-launch) LAUNCH=0 ;;
        *) echo "未知参数: $arg"; exit 1 ;;
    esac
done

# 安装位置：默认 /Applications（保证机器上只有一份），不可写或 --local 时退回 dist/
if [ "$LOCAL_ONLY" = "1" ]; then
    APP_DIR="dist/$APP_NAME.app"
else
    APP_DIR="$INSTALL_DIR/$APP_NAME.app"
    if [ ! -w "$INSTALL_DIR" ]; then
        echo "==> $INSTALL_DIR 不可写，改为打包到本目录 dist/"
        APP_DIR="dist/$APP_NAME.app"
    fi
fi

export CLANG_MODULE_CACHE_PATH="$PWD/$BUILD/modulecache"
export SWIFT_MODULECACHE_PATH="$PWD/$BUILD/modulecache"
mkdir -p "$BUILD/modulecache"

COMMON_FLAGS=(
    -O -wmo
    # ⚠️ **必须显式钉住 Swift 5 语言模式**，不能靠 swiftc 的默认值。
    # 实测：同一份源码加 `-swift-version 6` 会直接报 12 个 error
    # （Preferences.shared / LaunchAtLogin.shared / MenuBarImage.slotWidthCache /
    #  SingleInstance.lockDescriptor 都不是并发安全的全局状态，Monitors 里还引用了
    #  `vm_kernel_page_size` 这个可变全局量……）。现在能编过只是因为当前工具链默认落在
    # Swift 5 模式；哪天 Xcode 把默认值改成 6，这个项目会毫无预兆地编不过。
    -swift-version 5
    -module-cache-path "$PWD/$BUILD/modulecache"
    -framework IOKit
    -framework AppKit
    -framework SwiftUI
    -framework ServiceManagement
)

build_arch() {
    local arch="$1"
    swiftc "${COMMON_FLAGS[@]}" -target "${arch}-apple-macosx14.0" \
        -o "$BUILD/$APP_NAME-$arch" Sources/SysPulse/*.swift
}

echo "==> 编译"
rm -f "$BUILD/$APP_NAME" "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
if build_arch arm64 && build_arch x86_64; then
    lipo -create -output "$BUILD/$APP_NAME" "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
    echo "    通用二进制 (arm64 + x86_64)"
else
    echo "    x86_64 交叉编译不可用，改用 arm64"
    build_arch arm64
    mv "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME"
fi

if [ ! -f "Resources/AppIcon.icns" ]; then
    echo "==> 生成图标"
    swift Tools/MakeIcon.swift || echo "    (图标生成失败，跳过)"
fi

WAS_RUNNING=0
if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    WAS_RUNNING=1
    echo "==> 退出正在运行的实例"
    pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" || true
    sleep 1
fi

echo "==> 打包 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# 把构建指纹写进**打包后**的 Info.plist（必须在 codesign 之前）。
#
# 为什么需要：历史文档里反复出现"装的是不是新版本"这个坑 —— 比 md5 不行
# （codesign 会改二进制内容），比时间戳也会被骗（安装时机不同）。
# 现在一条命令就能确认：
#   defaults read /Applications/SysPulse.app/Contents/Info CFBundleVersion
#   defaults read /Applications/SysPulse.app/Contents/Info SysPulseBuildStamp
# CFBundleVersion 用 git 提交数（单调递增、纯数字，系统也认）；
# SysPulseBuildStamp 记短哈希 + 是否有未提交改动 + 构建时刻，用来反查是哪一版。
BUILD_REV="unknown"; BUILD_COUNT=0; BUILD_DIRTY=""
if git rev-parse --git-dir >/dev/null 2>&1; then
    BUILD_REV=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
    BUILD_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo 0)
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        BUILD_DIRTY="-dirty"     # 有未提交改动：装的东西不等于那个提交
    fi
fi
BUILD_STAMP="${BUILD_REV}${BUILD_DIRTY}@$(date '+%Y%m%d-%H%M%S')"
PLIST="$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_COUNT" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Set :SysPulseBuildStamp $BUILD_STAMP" "$PLIST" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add :SysPulseBuildStamp string $BUILD_STAMP" "$PLIST" >/dev/null 2>&1 \
    || true
echo "    构建指纹: $BUILD_STAMP   (CFBundleVersion = $BUILD_COUNT)"

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || echo "    (临时签名跳过，本机仍可运行)"

# 装到 /Applications 时，顺手清掉本目录可能残留的旧副本，避免出现两份
if [ "$APP_DIR" = "$INSTALL_DIR/$APP_NAME.app" ] && [ -d "dist/$APP_NAME.app" ]; then
    echo "==> 清理旧的本目录副本 dist/$APP_NAME.app"
    rm -rf "dist/$APP_NAME.app"
fi

echo "==> 完成: $APP_DIR"
if [ "$APP_DIR" = "$INSTALL_DIR/$APP_NAME.app" ]; then
    echo "    自检: \"$APP_DIR/Contents/MacOS/$APP_NAME\" --dump"
    if [ "$LAUNCH" = "1" ]; then
        open "$APP_DIR"
    fi
else
    echo "    启动: open \"$APP_DIR\""
fi
